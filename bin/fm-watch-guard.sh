#!/usr/bin/env bash
# fm-watch-guard.sh - quota-safe local recovery guard for a Firstmate home watcher.
# Uses Firstmate's strict readiness verdict and home-scoped restart lifecycle;
# never treats a live PID alone as healthy supervision, serializes overlapping
# timer ticks with flock, and never forkbombs restarts when no Firstmate harness
# holds the home lock (lock=free) or when no supervision model is bound.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME_MAIN="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_WATCH_GUARD_LOCK="${FM_WATCH_GUARD_LOCK:-${TMPDIR:-/tmp}/fm-watch-guard.$(id -u).lock}"
FM_HOME_SUMMARY_TIMEOUT="${FM_HOME_SUMMARY_TIMEOUT:-180}"
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"

# Serialize guard runs so overlapping timer invocations never pile up.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$FM_WATCH_GUARD_LOCK"
  if ! flock -n 9; then
    exit 0
  fi
fi

FM_READY_CMD="$FM_HOME_MAIN/bin/fm-inbox.sh"
FM_WATCH_ARM="$FM_HOME_MAIN/bin/fm-watch-arm.sh"
FM_WATCH_LOG="$FM_HOME_MAIN/state/watch-guard.log"

guard_log() {
  mkdir -p "$(dirname "$FM_WATCH_LOG")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$1" >> "$FM_WATCH_LOG"
}

read_readiness() {
  FM_HOME="$FM_HOME_MAIN" "$FM_READY_CMD" ready 2>>"$FM_WATCH_LOG"
}

read_can_receive() {
  local value
  value=$(printf '%s\n' "$1" | sed -n 's/.*"can_receive":[[:space:]]*"\{0,1\}\(true\|false\|unknown\)"\{0,1\}.*/\1/p' | head -n 1)
  printf '%s\n' "${value:-unknown}"
}

read_wake_reason() {
  printf '%s\n' "$1" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -n 1
}

read_lock_state() {
  printf '%s\n' "$1" | sed -n 's/.*"lock":{"state":"\([^"]*\)".*/\1/p' | head -n 1
}

[ -d "$FM_HOME_MAIN" ] || exit 0
[ -x "$FM_READY_CMD" ] && [ -x "$FM_WATCH_ARM" ] || {
  guard_log "recovery unavailable: Firstmate readiness or arm command is missing"
  exit 1
}

READY_JSON=$(read_readiness) || {
  guard_log "readiness check failed; no recovery attempted"
  exit 1
}
CAN_RECEIVE=$(read_can_receive "$READY_JSON")
WAKE_REASON=$(read_wake_reason "$READY_JSON")
LOCK_STATE=$(read_lock_state "$READY_JSON")

# Do NOT churn fm-watch restarts when no Firstmate harness is running (lock=free)
# or when the home has no active supervision model bound.
if [ "$LOCK_STATE" = "free" ] || [ "$WAKE_REASON" = "supervision-model-unknown-for-home" ]; then
  exit 0
fi

case "$CAN_RECEIVE" in
  true)
    exit 0
    ;;
  false)
    ;;
  unknown)
    if [ "$WAKE_REASON" != no-watcher ]; then
      guard_log "readiness is unknown (reason=${WAKE_REASON:-missing}); refusing automatic restart"
      exit 1
    fi
    ;;
  *)
    guard_log "readiness is unrecognized; refusing automatic restart"
    exit 1
    ;;
esac

RECOVERY_UNIT="fm-watch-main-$(date +%s)"
guard_log "readiness can_receive=false (lock=$LOCK_STATE reason=${WAKE_REASON:-none}); starting home-scoped fm-watch-arm --restart as $RECOVERY_UNIT"
systemd-run --user --collect --unit="$RECOVERY_UNIT" \
  --working-directory="$FM_HOME_MAIN" \
  --setenv="FM_HOME=$FM_HOME_MAIN" \
  --setenv="FM_HOME_SUMMARY_TIMEOUT=$FM_HOME_SUMMARY_TIMEOUT" \
  --setenv="PATH=/usr/local/bin:$HOME/.local/bin:$PATH" \
  -- "$FM_WATCH_ARM" --restart >>"$FM_WATCH_LOG" 2>&1 || {
    guard_log "systemd could not start the recovery arm"
    exit 1
  }

ATTEMPT=0
while [ "$ATTEMPT" -lt 45 ]; do
  READY_JSON=$(read_readiness 2>/dev/null || true)
  CAN_RECEIVE=$(read_can_receive "$READY_JSON")
  if [ "$CAN_RECEIVE" = true ]; then
    guard_log "recovery verified: can_receive=true"
    exit 0
  fi
  sleep 1
  ATTEMPT=$((ATTEMPT + 1))
done

guard_log "recovery arm started but did not verify within 45 seconds"
exit 1

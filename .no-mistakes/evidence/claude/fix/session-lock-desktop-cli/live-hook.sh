#!/usr/bin/env bash
set -u
root=/home/ryzengrind/.no-mistakes/worktrees/27179effe3d7/01M77BEGTK6X83V8DHJXSWDF34
run="$root/.test-session-lock/$LOCK_TEST_ROLE"
state="$root/.test-session-lock/$LOCK_TEST_STATE"
mkdir -p "$run" "$state"
exec > "$run/transcript.log" 2>&1
cat > "$run/hook-input.json"
printf 'Role: %s\nCLAUDE_PID=%s\nCLAUDE_CODE_SESSION_ID=%s\n' "$LOCK_TEST_ROLE" "${CLAUDE_PID:-}" "${CLAUDE_CODE_SESSION_ID:-}"
printf '%s\n' "$CLAUDE_PID" > "$run/pid"
ps -o pid=,ppid=,comm=,args= -p "$CLAUDE_PID"
. "$root/bin/fm-session-lock-lib.sh"
fm_harness_pid_alive "$CLAUDE_PID"
printf 'Desktop process recognized as harness: rc=%s\n' "$?"
lock="$root/bin/fm-lock.sh"
[ "$LOCK_TEST_ROLE" != baseline ] || lock="$root/.test-session-lock/base/bin/fm-lock.sh"
printf '\n$ fm-lock.sh\n'
FM_STATE_OVERRIDE="$state" bash "$lock"
printf '%s\n' "$?" > "$run/acquire.rc"
printf 'Acquisition exit: %s\n' "$(cat "$run/acquire.rc")"
printf '\n$ fm-lock.sh status\n'
FM_STATE_OVERRIDE="$state" bash "$lock" status
if [ "$LOCK_TEST_ROLE" = owner ] || [ "$LOCK_TEST_ROLE" = reclaim ]; then
  cp "$state/.lock" "$run/lock-before"
  cp "$state/.lock-session" "$run/session-before"
  printf '\n$ fm-lock.sh (same-session confirmation)\n'
  FM_STATE_OVERRIDE="$state" bash "$lock"
  printf '%s\n' "$?" > "$run/confirm.rc"
  cmp "$run/lock-before" "$state/.lock" && cmp "$run/session-before" "$state/.lock-session"
  printf 'Lock and session sidecar unchanged: rc=%s\n' "$?"
fi
printf '\nPersisted lock pid: '; cat "$state/.lock" 2>/dev/null || true
printf 'Persisted session id: '; cat "$state/.lock-session" 2>/dev/null || true
touch "$run/ready"
if [ "$LOCK_TEST_ROLE" = owner ]; then
  for attempt in {1..600}; do
    [ ! -e "$run/release" ] || break
    sleep 0.1
  done
fi

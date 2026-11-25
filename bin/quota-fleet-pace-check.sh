#!/usr/bin/env bash
# Warn if any quota-axi provider drops below the warn threshold.
# Thin wrapper around `quota-axi --json`; the provider catalogue and schema live
# in quota-axi itself. Called from Claude Code hooks; must never block work and
# always exits 0.
#
# Uses a file-backed stale-while-revalidate cache so hook invocations return in
# a few milliseconds instead of stalling on a slow or timing-out `quota-axi`
# call on every PreToolUse/PostToolUse/Stop turn. Pass --sync (or --no-cache)
# for a synchronous refresh.

set -u

SELF_PATH="${BASH_SOURCE[0]}"
WARN_AT=20
SYNC_MODE=0
NO_CACHE=0
REFRESH_WORKER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --warn-at)
      shift
      WARN_AT="${1:-20}"
      ;;
    --warn-at=*)
      WARN_AT="${1#--warn-at=}"
      ;;
    --sync)
      SYNC_MODE=1
      ;;
    --no-cache)
      NO_CACHE=1
      SYNC_MODE=1
      ;;
    --_refresh)
      REFRESH_WORKER=1
      ;;
    *) ;;
  esac
  shift
done

case "$WARN_AT" in
  ''|*[!0-9]*) WARN_AT=20 ;;
esac

command -v quota-axi >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CACHE_FILE="${FM_QUOTA_PACE_CACHE:-${TMPDIR:-/tmp}/fm-quota-pace-cache.${UID:-0}.json}"
STAMP_FILE="${CACHE_FILE}.stamp"
LOCK_FILE="${CACHE_FILE}.lock"
OUT_FILE="${CACHE_FILE}.w${WARN_AT}.out"

CACHE_TTL="${FM_QUOTA_PACE_CACHE_TTL:-60}"
case "$CACHE_TTL" in ''|*[!0-9]*) CACHE_TTL=60 ;; esac
FAIL_TTL="${FM_QUOTA_PACE_FAIL_TTL:-60}"
case "$FAIL_TTL" in ''|*[!0-9]*) FAIL_TTL=60 ;; esac
STALE_MAX="${FM_QUOTA_PACE_STALE_MAX:-600}"
case "$STALE_MAX" in ''|*[!0-9]*) STALE_MAX=600 ;; esac
FETCH_TIMEOUT="${FM_QUOTA_PACE_TIMEOUT:-3}"
case "$FETCH_TIMEOUT" in ''|*[!0-9]*|0) FETCH_TIMEOUT=3 ;; esac

NOW=
if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] \
  || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
  printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=
fi
[ -n "$NOW" ] || NOW=$(date +%s 2>/dev/null || printf '0')

_quota_render_json() {  # <json-file>
  jq -r --argjson warn "$WARN_AT" '
    .providers[]?
    | select(.quotaSemantics.status == "known")
    | . as $p
    | (.quotaSemantics.effectiveAvailability // [])[]?
    | select(.status == "known" and .effectivePercentRemaining < $warn)
    | "⚠️  Quota: \($p.provider) (\(.scope)) at \(.effectivePercentRemaining | floor)% remaining"
  ' "$1" 2>/dev/null || true
}

_quota_write_atomic() {  # <target> <content>
  local target=$1 content=$2 dir tmp
  dir=$(dirname "$target")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "${target}.tmp.XXXXXX" 2>/dev/null) || return 1
  if [ -n "$content" ]; then
    printf '%s\n' "$content" > "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
  else
    : > "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
  fi
  mv -f -- "$tmp" "$target" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null || true; return 1; }
}

_quota_refresh_locked() {
  local snap rendered
  if command -v timeout >/dev/null 2>&1; then
    snap=$(timeout "$FETCH_TIMEOUT" quota-axi --json --max-age 60 2>/dev/null) || snap=
  else
    snap=$(quota-axi --json --max-age 60 2>/dev/null) || snap=
  fi
  if [ -n "$snap" ] && printf '%s\n' "$snap" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _quota_write_atomic "$CACHE_FILE" "$snap" || true
    # Invalidate pre-rendered threshold files for other --warn-at values.
    rm -f -- "${CACHE_FILE}".w*.out 2>/dev/null || true
    rendered=$(_quota_render_json "$CACHE_FILE")
    _quota_write_atomic "$OUT_FILE" "$rendered" || true
    _quota_write_atomic "$STAMP_FILE" "${NOW}	ok	${NOW}" || true
  else
    # Preserve last known ok epoch on failure so stale-while-revalidate can bound its age.
    local prev_ok="" s_ok=""
    if [ -r "$STAMP_FILE" ]; then
      IFS=$'\t' read -r _ _ s_ok < "$STAMP_FILE" 2>/dev/null || true
      prev_ok=${s_ok:-}
    fi
    _quota_write_atomic "$STAMP_FILE" "${NOW}	fail	${prev_ok}" || true
  fi
}

_quota_run_refresh() {  # <nonblocking: 1|0>
  local nb=$1 dir lock_d
  dir=$(dirname "$CACHE_FILE")
  mkdir -p "$dir" 2>/dev/null || return 0
  if command -v flock >/dev/null 2>&1; then
    if [ "$nb" -eq 1 ]; then
      (
        flock -n 9 || exit 0
        _quota_refresh_locked
      ) 9>"$LOCK_FILE"
    else
      (
        flock -w 5 9 || exit 0
        _quota_refresh_locked
      ) 9>"$LOCK_FILE"
    fi
  else
    lock_d="${LOCK_FILE}.d"
    if mkdir "$lock_d" 2>/dev/null; then
      # shellcheck disable=SC2064
      trap "rmdir '$lock_d' 2>/dev/null || true" EXIT
      _quota_refresh_locked
      rmdir "$lock_d" 2>/dev/null || true
      trap - EXIT
    fi
  fi
}

if [ "$REFRESH_WORKER" -eq 1 ]; then
  _quota_run_refresh 1
  exit 0
fi

if [ "$SYNC_MODE" -eq 1 ]; then
  if [ "$NO_CACHE" -eq 1 ]; then
    _quota_refresh_locked
  else
    _quota_run_refresh 0
  fi
  if [ -r "$OUT_FILE" ]; then
    [ -s "$OUT_FILE" ] && cat "$OUT_FILE"
  elif [ -r "$CACHE_FILE" ] && [ -s "$CACHE_FILE" ]; then
    _quota_render_json "$CACHE_FILE"
  fi
  exit 0
fi

# Fast hook path: check stamp without forking external processes.
STAMP_TS=""
STAMP_STATUS=""
STAMP_OK_TS=""
if [ -r "$STAMP_FILE" ]; then
  IFS=$'\t' read -r STAMP_TS STAMP_STATUS STAMP_OK_TS < "$STAMP_FILE" 2>/dev/null || true
fi

CACHE_FRESH=0
if [ -n "$STAMP_TS" ]; then
  case "$STAMP_TS" in
    *[!0-9]*) ;;
    *)
      AGE=$((NOW - STAMP_TS))
      [ "$AGE" -ge 0 ] || AGE=0
      if [ "$STAMP_STATUS" = "ok" ] && [ "$AGE" -lt "$CACHE_TTL" ]; then
        CACHE_FRESH=1
      elif [ "$STAMP_STATUS" = "fail" ] && [ "$AGE" -lt "$FAIL_TTL" ]; then
        CACHE_FRESH=1
      fi
      ;;
  esac
fi

# Emit cached output if still within STALE_MAX of the last good fetch.
CAN_EMIT=0
if [ -n "$STAMP_OK_TS" ]; then
  case "$STAMP_OK_TS" in
    *[!0-9]*) ;;
    *)
      OK_AGE=$((NOW - STAMP_OK_TS))
      [ "$OK_AGE" -ge 0 ] || OK_AGE=0
      [ "$OK_AGE" -le "$STALE_MAX" ] && CAN_EMIT=1
      ;;
  esac
fi

if [ "$CAN_EMIT" -eq 1 ]; then
  if [ -r "$OUT_FILE" ]; then
    [ -s "$OUT_FILE" ] && cat "$OUT_FILE"
  elif [ -r "$CACHE_FILE" ] && [ -s "$CACHE_FILE" ]; then
    RENDERED=$(_quota_render_json "$CACHE_FILE")
    _quota_write_atomic "$OUT_FILE" "$RENDERED" || true
    [ -n "$RENDERED" ] && printf '%s\n' "$RENDERED"
  fi
fi

# Fresh cache hit: zero background work needed.
if [ "$CACHE_FRESH" -eq 1 ]; then
  exit 0
fi

# Stale or cold cache: kick a detached background refresh and return immediately
# with stdout/stderr closed so the calling hook never blocks on pipe EOF.
(
  exec </dev/null >/dev/null 2>&1
  FM_QUOTA_PACE_CACHE="$CACHE_FILE" \
    FM_QUOTA_PACE_CACHE_TTL="$CACHE_TTL" \
    FM_QUOTA_PACE_FAIL_TTL="$FAIL_TTL" \
    FM_QUOTA_PACE_STALE_MAX="$STALE_MAX" \
    FM_QUOTA_PACE_TIMEOUT="$FETCH_TIMEOUT" \
    "$SELF_PATH" --_refresh --warn-at "$WARN_AT" &
)

exit 0

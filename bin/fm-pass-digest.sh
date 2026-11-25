#!/usr/bin/env bash
# fm-pass-digest.sh - single-call batched supervision pass digest for Firstmate.
#
# Combines lock/watcher/AFK readiness, wake-queue peek (or --drain), cached
# bearings snapshot (fm-bearings-snapshot.sh --fast), and MCP-first context
# discovery endpoints (MCP_GATEWAY_URL, GRAPHIFY_URL) into ONE fast, byte-capped
# tool call so fast-tier models (Luna/Haiku) avoid 8-12 serial shell turns per
# supervision pass.
#
# Usage:
#   fm-pass-digest.sh [--json] [--live] [--drain] [--mcp-probe] [--max-bytes <N>]
#
# Flags:
#   --json          emit structured JSON (schema: fm-pass-digest.v1)
#   --live          bypass bearings cache (--no-cache)
#   --drain         delegate wake section to bin/fm-wake-drain.sh (mutating)
#   --mcp-probe     run a bounded 1s cached reachability probe on MCP endpoints
#   --max-bytes <N> cap bearings text section (default: 6144 fast / 16384 standard)
#   -h, --help      show this help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-model-tier-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-model-tier-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

FORMAT=text
LIVE_MODE=0
DRAIN_MODE=0
MCP_PROBE=0
MAX_BYTES_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --live) LIVE_MODE=1 ;;
    --drain) DRAIN_MODE=1 ;;
    --mcp-probe) MCP_PROBE=1 ;;
    --max-bytes)
      shift
      [ $# -gt 0 ] || { usage >&2; exit 2; }
      MAX_BYTES_ARG=$1
      ;;
    --max-bytes=*)
      MAX_BYTES_ARG=${1#--max-bytes=}
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

TIER=$(fm_model_tier)
MODEL=$(fm_detect_model_name 2>/dev/null || true)
[ -n "$MODEL" ] || MODEL="auto"

if [ -n "$MAX_BYTES_ARG" ]; then
  MAX_BYTES=$MAX_BYTES_ARG
elif [ -n "${FM_PASS_DIGEST_MAX_BYTES:-}" ]; then
  MAX_BYTES=$FM_PASS_DIGEST_MAX_BYTES
elif [ "$TIER" = "fast" ]; then
  MAX_BYTES=6144
else
  MAX_BYTES=16384
fi
case "$MAX_BYTES" in ''|*[!0-9]*|0) MAX_BYTES=6144 ;; esac

WAKE_PEEK_LINES=${FM_PASS_WAKE_PEEK_LINES:-6}
case "$WAKE_PEEK_LINES" in ''|*[!0-9]*) WAKE_PEEK_LINES=6 ;; esac

NOW_EPOCH=
if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] \
  || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
  printf -v NOW_EPOCH '%(%s)T' -1 2>/dev/null || NOW_EPOCH=
fi
[ -n "$NOW_EPOCH" ] || NOW_EPOCH=$(date +%s 2>/dev/null || printf '0')

# --- 1. fast read-only readiness (lock, watcher, AFK) -----------------------
LOCK_STATE="free"
LOCK_PID=""
if [ -r "$STATE/.lock" ]; then
  LOCK_PID=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -d '[:space:]')
  case "$LOCK_PID" in
    ''|*[!0-9]*) LOCK_STATE="corrupt" ;;
    *)
      if kill -0 "$LOCK_PID" 2>/dev/null; then
        LOCK_STATE="held"
      else
        LOCK_STATE="stale"
      fi
      ;;
  esac
fi

WATCHER_STATE="none"
WATCHER_PID=""
if [ -r "$STATE/.watcher-pid" ]; then
  WATCHER_PID=$(head -n 1 "$STATE/.watcher-pid" 2>/dev/null | tr -d '[:space:]')
  case "$WATCHER_PID" in
    ''|*[!0-9]*) WATCHER_STATE="corrupt" ;;
    *)
      if kill -0 "$WATCHER_PID" 2>/dev/null; then
        WATCHER_STATE="alive"
      else
        WATCHER_STATE="dead"
      fi
      ;;
  esac
fi

AFK_STATE="absent"
if [ -f "$STATE/.afk-contract" ]; then
  if [ -x "$SCRIPT_DIR/fm-afk-contract.sh" ]; then
    AFK_STATE=$("$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null || printf 'away')
  else
    AFK_STATE="away"
  fi
elif [ -e "$STATE/.afk" ]; then
  AFK_STATE="away"
fi

# --- 2. wake queue peek (read-only) or --drain ------------------------------
WAKE_QUEUE_FILE="$STATE/.wake-queue"
WAKE_COUNT=0
WAKE_SUMMARY=""
WAKE_RC=0
if [ "$DRAIN_MODE" -eq 1 ]; then
  WAKE_SUMMARY=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1) || WAKE_RC=$?
  if [ -r "$WAKE_QUEUE_FILE" ]; then
    WAKE_COUNT=$(wc -l < "$WAKE_QUEUE_FILE" 2>/dev/null | tr -d '[:space:]')
  fi
else
  if [ -r "$WAKE_QUEUE_FILE" ] && [ -s "$WAKE_QUEUE_FILE" ]; then
    WAKE_COUNT=$(wc -l < "$WAKE_QUEUE_FILE" 2>/dev/null | tr -d '[:space:]')
    WAKE_SUMMARY=$(tail -n "$WAKE_PEEK_LINES" "$WAKE_QUEUE_FILE" 2>/dev/null \
      | awk '{ if (length($0) > 140) print substr($0, 1, 137) "..."; else print $0 }')
  fi
fi
case "$WAKE_COUNT" in ''|*[!0-9]*) WAKE_COUNT=0 ;; esac

INBOX_NONEMPTY=0
for _inb in "$STATE"/*.inbox; do
  [ -f "$_inb" ] && [ -s "$_inb" ] || continue
  INBOX_NONEMPTY=$((INBOX_NONEMPTY + 1))
done

# --- 3. cached bearings snapshot --------------------------------------------
BEARINGS_ARGS=()
if [ "$LIVE_MODE" -eq 1 ]; then
  BEARINGS_ARGS+=(--no-cache)
else
  BEARINGS_ARGS+=(--fast)
fi
if [ "$FORMAT" = "json" ]; then
  BEARINGS_ARGS+=(--json)
fi

BEARINGS_OUT=""
BEARINGS_ERR=""
BEARINGS_RC=0
_b_err_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-pass-berr.XXXXXX" 2>/dev/null) || _b_err_file=""
if [ -n "$_b_err_file" ]; then
  BEARINGS_OUT=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" "${BEARINGS_ARGS[@]}" 2>"$_b_err_file") || BEARINGS_RC=$?
  BEARINGS_ERR=$(cat "$_b_err_file" 2>/dev/null || true)
  rm -f -- "$_b_err_file" 2>/dev/null || true
else
  BEARINGS_OUT=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" "${BEARINGS_ARGS[@]}" 2>&1) || BEARINGS_RC=$?
fi

# --- 4. MCP-first fast-context discovery ------------------------------------
MCP_GW=$(fm_mcp_gateway_url)
GRAPHIFY=$(fm_graphify_url)
MCP_GW_STATUS="unprobed"
GRAPHIFY_STATUS="unprobed"

_probe_url_cached() {  # <url> <key>
  local url=$1 key=$2 cache_f ts st age rc
  cache_f="${TMPDIR:-/tmp}/fm-mcp-probe.${UID:-0}.${key}.cache"
  if [ -r "$cache_f" ]; then
    IFS=$'\t' read -r ts st < "$cache_f" 2>/dev/null || true
    case "${ts:-}" in
      ''|*[!0-9]*) ;;
      *)
        age=$((NOW_EPOCH - ts))
        if [ "$age" -ge 0 ] && [ "$age" -lt 120 ] && [ -n "${st:-}" ]; then
          printf '%s\n' "$st"
          return 0
        fi
        ;;
    esac
  fi
  if ! command -v curl >/dev/null 2>&1; then
    printf 'no-curl\n'
    return 0
  fi
  rc=0
  curl -sfI --max-time 1 "$url" >/dev/null 2>&1 || rc=$?
  # Any HTTP response (even 401/403/404) proves the endpoint is reachable; curl
  # exit 22 is HTTP >=400 (service alive behind auth).
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 22 ]; then
    st="reachable"
  else
    st="unreachable"
  fi
  printf '%s\t%s\n' "$NOW_EPOCH" "$st" > "$cache_f" 2>/dev/null || true
  printf '%s\n' "$st"
}

if [ "$MCP_PROBE" -eq 1 ]; then
  MCP_GW_STATUS=$(_probe_url_cached "$MCP_GW" "mcp-gw")
  GRAPHIFY_STATUS=$(_probe_url_cached "$GRAPHIFY" "graphify")
fi

# --- output -----------------------------------------------------------------
if [ "$FORMAT" = "json" ]; then
  command -v jq >/dev/null 2>&1 || { echo "fm-pass-digest: jq not found" >&2; exit 1; }
  BEARINGS_JSON="null"
  if [ "$BEARINGS_RC" -eq 0 ] && [ -n "$BEARINGS_OUT" ] \
    && printf '%s' "$BEARINGS_OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    BEARINGS_JSON=$BEARINGS_OUT
  fi
  jq -n \
    --arg schema "fm-pass-digest.v1" \
    --arg tier "$TIER" \
    --arg model "$MODEL" \
    --arg home "$FM_HOME" \
    --arg lock_state "$LOCK_STATE" \
    --arg lock_pid "$LOCK_PID" \
    --arg watcher_state "$WATCHER_STATE" \
    --arg watcher_pid "$WATCHER_PID" \
    --arg afk "$AFK_STATE" \
    --argjson wake_count "$WAKE_COUNT" \
    --argjson wake_drained "$DRAIN_MODE" \
    --argjson wake_rc "$WAKE_RC" \
    --arg wake_summary "$WAKE_SUMMARY" \
    --argjson inbox_nonempty "$INBOX_NONEMPTY" \
    --argjson bearings_rc "$BEARINGS_RC" \
    --arg bearings_error "$BEARINGS_ERR" \
    --argjson bearings "$BEARINGS_JSON" \
    --arg mcp_gw "$MCP_GW" \
    --arg mcp_gw_status "$MCP_GW_STATUS" \
    --arg graphify "$GRAPHIFY" \
    --arg graphify_status "$GRAPHIFY_STATUS" \
    '{
      schema: $schema,
      tier: $tier,
      model: $model,
      home: $home,
      readiness: {
        lock: { state: $lock_state, pid: (if $lock_pid == "" then null else $lock_pid end) },
        watcher: { state: $watcher_state, pid: (if $watcher_pid == "" then null else $watcher_pid end) },
        afk: $afk
      },
      wake_queue: {
        pending_lines: $wake_count,
        drained: ($wake_drained == 1),
        exit_code: $wake_rc,
        inbox_nonempty_files: $inbox_nonempty,
        preview: $wake_summary
      },
      bearings: {
        exit_code: $bearings_rc,
        error: (if $bearings_error == "" then null else $bearings_error end),
        snapshot: $bearings
      },
      mcp: {
        gateway_url: $mcp_gw,
        gateway_status: $mcp_gw_status,
        graphify_url: $graphify,
        graphify_status: $graphify_status,
        guidance: "Prefer 1 structured Graphify/MCP Gateway query over serial grep/shell turns."
      }
    }'
  exit 0
fi

printf '=== FM PASS DIGEST (tier=%s model=%s) ===\n' "$TIER" "$MODEL"
printf 'home: %s\n' "$FM_HOME"
printf 'readiness: lock=%s%s watcher=%s%s afk=%s\n' \
  "$LOCK_STATE" "${LOCK_PID:+($LOCK_PID)}" \
  "$WATCHER_STATE" "${WATCHER_PID:+($WATCHER_PID)}" \
  "$AFK_STATE"
printf 'wake_queue: pending=%s inbox_nonempty=%s mode=%s\n' \
  "$WAKE_COUNT" "$INBOX_NONEMPTY" "$([ "$DRAIN_MODE" -eq 1 ] && printf drain || printf peek)"
if [ -n "$WAKE_SUMMARY" ]; then
  printf '%s\n' "$WAKE_SUMMARY"
fi

printf '\n--- MCP-FIRST CONTEXT DISCOVERY ---\n'
printf 'graphify: %s (%s)\n' "$GRAPHIFY" "$GRAPHIFY_STATUS"
printf 'mcp_gateway: %s (%s)\n' "$MCP_GW" "$MCP_GW_STATUS"
printf 'hint: query Graphify/MCP in 1 structured call before running serial grep/shell turns.\n'

printf '\n--- BEARINGS (%s, max %s B) ---\n' \
  "$([ "$LIVE_MODE" -eq 1 ] && printf live || printf cached)" "$MAX_BYTES"
if [ "$BEARINGS_RC" -ne 0 ]; then
  printf 'bearings unavailable (exit %s): %s\n' "$BEARINGS_RC" "${BEARINGS_ERR:-see fm-bearings-snapshot.sh}"
else
  B_SIZE=${#BEARINGS_OUT}
  if [ "$B_SIZE" -gt "$MAX_BYTES" ]; then
    printf '%s\n' "${BEARINGS_OUT:0:$MAX_BYTES}"
    printf '[pass-digest: bearings truncated at %s of %s bytes; run bin/fm-bearings-snapshot.sh --fast for full view]\n' \
      "$MAX_BYTES" "$B_SIZE"
  else
    printf '%s\n' "$BEARINGS_OUT"
  fi
fi

exit 0

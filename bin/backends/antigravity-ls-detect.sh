#!/usr/bin/env bash
# antigravity-ls-detect.sh - resolve ANTIGRAVITY_LS_ADDRESS by parsing the
# Antigravity IDE's per-session logs for the most recent LS gRPC port bind.
#
# Antigravity IDE binds a NEW ephemeral gRPC port on each launch. Two
# on-disk layouts are known:
#
#   v1 (pre-2026-06): a single main.log at
#       AppData/Roaming/Antigravity/logs/main.log
#     with `[Auto-Restart] Port changed! Reloading all windows with URL:
#     https://127.0.0.1:<PORT>/` on every rebind. The last hit is the
#     currently bound port.
#
#   v2 (2026-06+): per-session log DIRs at
#       AppData/Roaming/Antigravity IDE/logs/<YYYYMMDDTHHMMSS>/
#     each containing an ls-main.log with two matching shapes:
#       `LS started on port <PORT>` (the definitive `[LS Main]` line), and
#       `Language server listening on random port at <PORT> for HTTPS (gRPC)`
#     The gRPC port is the ANTIGRAVITY_LS_ADDRESS target; the HTTP port is
#     a sibling on the same host and is NOT what agentapi dials. This
#     helper prefers the newest v2 session's port and falls back to v1.
#
# agentapi refuses every call with `{"error":"ANTIGRAVITY_LS_ADDRESS is not
# set"}` unless the address is in the environment, so this helper extracts
# the current port and prints `127.0.0.1:<PORT>` on stdout for the fm-spawn
# preflight (and any operator shell that sources it) to pick up.
#
# Usage:
#   antigravity-ls-detect.sh                 print 127.0.0.1:<PORT> on stdout
#   antigravity-ls-detect.sh --export        emit `export ANTIGRAVITY_LS_ADDRESS=...`
#
# Environment:
#   FM_ANTIGRAVITY_IDE_LOG_DIR - v2 override. Default:
#       /mnt/c/Users/${WSL_USER:-$USER}/AppData/Roaming/Antigravity IDE/logs
#   FM_ANTIGRAVITY_IDE_LOG - v1 fallback override. Default:
#       /mnt/c/Users/${WSL_USER:-$USER}/AppData/Roaming/Antigravity/logs/main.log
#
# Exit codes:
#   0 - a port was resolved and printed.
#   2 - neither layout is reachable; operator has not launched the IDE yet
#       or the path overrides are wrong.
#   3 - a log was found but contains no port-bind line; the IDE has not
#       finished starting (still on the pre-bind splash, or crashed early).
set -u

MODE=print
case "${1:-}" in
  --export) MODE=export ;;
  '') : ;;
  *) echo "antigravity-ls-detect: unknown arg '$1' (accepts --export or no arg)" >&2; exit 2 ;;
esac

USER_NAME=${WSL_USER:-$USER}
DEFAULT_V2_DIR="/mnt/c/Users/$USER_NAME/AppData/Roaming/Antigravity IDE/logs"
DEFAULT_V1_LOG="/mnt/c/Users/$USER_NAME/AppData/Roaming/Antigravity/logs/main.log"

V2_DIR=${FM_ANTIGRAVITY_IDE_LOG_DIR:-$DEFAULT_V2_DIR}
V1_LOG=${FM_ANTIGRAVITY_IDE_LOG:-$DEFAULT_V1_LOG}

PORT=

# v2 first: find the newest ls-main.log across per-session dirs. The
# `LS started on port <PORT>` line is the definitive one the IDE emits
# once its language server is up. `find ... -printf '%T@ %p\n'` orders by
# mtime so the freshest session wins even when the IDE has been relaunched
# multiple times.
if [ -d "$V2_DIR" ]; then
  # shellcheck disable=SC2016
  LATEST_LS_LOG=$(find "$V2_DIR" -maxdepth 3 -name 'ls-main.log' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -1 | awk '{ $1=""; sub(/^ /,""); print }')
  if [ -n "$LATEST_LS_LOG" ] && [ -r "$LATEST_LS_LOG" ]; then
    # Prefer the `LS started on port <PORT>` line - it is the last one the
    # IDE emits per bind, so ordering-wise it always represents the current
    # port. Fall back to `Language server listening on random port at
    # <PORT> for HTTPS (gRPC)` if the LS-started line is absent (older v2).
    PORT=$(grep -Eo 'LS started on port [0-9]{4,5}' "$LATEST_LS_LOG" 2>/dev/null | tail -1 | grep -Eo '[0-9]{4,5}')
    if [ -z "$PORT" ]; then
      PORT=$(grep -Eo 'random port at [0-9]{4,5} for HTTPS \(gRPC\)' "$LATEST_LS_LOG" 2>/dev/null | tail -1 | grep -Eo '[0-9]{4,5}')
    fi
  fi
fi

# v1 fallback.
if [ -z "$PORT" ] && [ -r "$V1_LOG" ]; then
  PORT=$(grep -Eo 'https://127\.0\.0\.1:[0-9]{4,5}/' "$V1_LOG" 2>/dev/null | tail -1 | grep -Eo '[0-9]{4,5}')
fi

if [ -z "$PORT" ]; then
  if [ ! -d "$V2_DIR" ] && [ ! -r "$V1_LOG" ]; then
    echo "antigravity-ls-detect: cannot read Antigravity IDE logs at '$V2_DIR' (v2) or '$V1_LOG' (v1) - launch the IDE at least once, or set FM_ANTIGRAVITY_IDE_LOG_DIR / FM_ANTIGRAVITY_IDE_LOG" >&2
    exit 2
  fi
  echo "antigravity-ls-detect: Antigravity IDE logs exist but hold no port-bind line - the IDE has not finished starting yet (or crashed before binding)" >&2
  exit 3
fi

ADDR="127.0.0.1:$PORT"
case "$MODE" in
  export) printf 'export ANTIGRAVITY_LS_ADDRESS=%s\n' "$ADDR" ;;
  *) printf '%s\n' "$ADDR" ;;
esac

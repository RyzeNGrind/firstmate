#!/usr/bin/env bash
# antigravity-ls-detect.sh - resolve ANTIGRAVITY_LS_ADDRESS by parsing the
# Antigravity IDE's main.log for the most recent port bind.
#
# Antigravity IDE binds an ephemeral HTTPS port on each launch (verified
# 2026-09-08 in the Windows install: `--https_server_port 0` on startup,
# followed by a `[Auto-Restart] Port changed! Reloading all windows with URL:
# https://127.0.0.1:<PORT>/` log line once the OS assigns one). agentapi
# refuses every call with `{"error":"ANTIGRAVITY_LS_ADDRESS is not set"}`
# unless the operator exports that address into the shell environment, so
# this helper extracts the most recent bound port from the log the IDE
# already writes and prints `127.0.0.1:<PORT>` on stdout.
#
# The IDE writes a SINGLE main.log per install, appended on every launch
# (not per session), so the LAST matching line always names the currently
# bound port. When the IDE is not running the port may be stale; the caller
# is responsible for verifying reachability (a stale port simply fails the
# next agentapi call with the standard connection error).
#
# Usage:
#   antigravity-ls-detect.sh                 print 127.0.0.1:<PORT> on stdout
#   antigravity-ls-detect.sh --export        emit `export ANTIGRAVITY_LS_ADDRESS=...`
#
# Environment:
#   FM_ANTIGRAVITY_IDE_LOG - override the main.log path. Default:
#       /mnt/c/Users/${WSL_USER:-$USER}/AppData/Roaming/Antigravity/logs/main.log
#       (WSL-under-Windows layout; a native Linux/macOS install would need
#       a different override).
#
# Exit codes:
#   0 - a port was found and printed.
#   2 - the log file is missing or unreadable; operator has not launched
#       the IDE yet, or the path override is wrong.
#   3 - the log exists but contains no port-bind lines; the IDE has never
#       finished a startup (still on the pre-bind splash, or crashed early).
set -u

MODE=print
case "${1:-}" in
  --export) MODE=export ;;
  '') : ;;
  *) echo "antigravity-ls-detect: unknown arg '$1' (accepts --export or no arg)" >&2; exit 2 ;;
esac

LOG=${FM_ANTIGRAVITY_IDE_LOG:-/mnt/c/Users/${WSL_USER:-$USER}/AppData/Roaming/Antigravity/logs/main.log}
if [ ! -r "$LOG" ]; then
  echo "antigravity-ls-detect: cannot read Antigravity IDE log at '$LOG' - launch the IDE at least once, or set FM_ANTIGRAVITY_IDE_LOG to its main.log path" >&2
  exit 2
fi

# Match both the "Port changed!" and the plain "Local:" lines the IDE emits
# once its HTTPS server has bound. The last hit wins.
PORT=$(grep -Eo 'https://127\.0\.0\.1:[0-9]{4,5}/' "$LOG" 2>/dev/null | tail -1 | grep -Eo '[0-9]{4,5}')
if [ -z "$PORT" ]; then
  echo "antigravity-ls-detect: Antigravity IDE log at '$LOG' has no port-bind line - the IDE has not finished starting yet (or crashed before binding)" >&2
  exit 3
fi

ADDR="127.0.0.1:$PORT"
case "$MODE" in
  export) printf 'export ANTIGRAVITY_LS_ADDRESS=%s\n' "$ADDR" ;;
  *) printf '%s\n' "$ADDR" ;;
esac

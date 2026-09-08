#!/usr/bin/env bash
# fm-antigravity-smoke.sh - post-OAuth diagnostic for the antigravity
# (agentapi) firstmate adapter. Prints a checklist of the states the
# adapter's credential preflight cares about and, if everything green,
# fires a batch new-conversation call to prove end-to-end reachability
# before the operator invests in spawning a real crewmate.
#
# Usage:
#   fm-antigravity-smoke.sh              full diagnostic + one live turn
#   fm-antigravity-smoke.sh --checks     stop after the state checklist
#   fm-antigravity-smoke.sh --repl       exercise the REPL wrapper instead
#                                        of a raw agentapi call
#
# Exits 0 when the live turn (or REPL exchange) reports response text on
# stdout. Exits non-zero and names the first failed check otherwise.
set -u

MODE=full
case "${1:-}" in
  --checks) MODE=checks ;;
  --repl) MODE=repl ;;
  '') : ;;
  *) echo "fm-antigravity-smoke: unknown arg '$1'" >&2; exit 2 ;;
esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
AGENTAPI_BIN=${FM_ANTIGRAVITY_BIN:-$HOME/.gemini/antigravity-cli/bin/agentapi}
TOKEN_PATH=${FM_ANTIGRAVITY_TOKEN_PATH:-$HOME/.gemini/antigravity-cli/antigravity-oauth-token}
REPL="$FM_ROOT/bin/backends/antigravity-repl.sh"
LS_DETECT="$FM_ROOT/bin/backends/antigravity-ls-detect.sh"

check() {  # <label> <cmd...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$label"
    return 0
  fi
  printf 'FAIL  %s\n' "$label"
  return 1
}

fails=0

echo "=== antigravity smoke: state checklist ==="

check "agentapi binary executable at $AGENTAPI_BIN" test -x "$AGENTAPI_BIN" || fails=$((fails+1))
check "oauth token file non-empty at $TOKEN_PATH" test -s "$TOKEN_PATH" || fails=$((fails+1))
check "oauth token holds a non-empty access_token" \
  grep -Eq '"access_token"[[:space:]]*:[[:space:]]*"[^"]+"' "$TOKEN_PATH" || fails=$((fails+1))
check "REPL wrapper executable at $REPL" test -x "$REPL" || fails=$((fails+1))
check "LS-detect helper executable at $LS_DETECT" test -x "$LS_DETECT" || fails=$((fails+1))

# LS_ADDRESS resolution: env first, auto-detect fallback.
if [ -n "${ANTIGRAVITY_LS_ADDRESS:-}" ]; then
  printf 'ok    ANTIGRAVITY_LS_ADDRESS set in env: %s\n' "$ANTIGRAVITY_LS_ADDRESS"
elif RESOLVED=$("$LS_DETECT" 2>/dev/null) && [ -n "$RESOLVED" ]; then
  printf 'ok    ANTIGRAVITY_LS_ADDRESS auto-detected from IDE log: %s\n' "$RESOLVED"
  export ANTIGRAVITY_LS_ADDRESS="$RESOLVED"
else
  printf 'FAIL  ANTIGRAVITY_LS_ADDRESS unresolved (env unset + IDE-log auto-detect empty)\n'
  fails=$((fails+1))
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d check(s) failed. Fix the failing rows before firing a live turn.\n' "$fails" >&2
  exit 3
fi

if [ "$MODE" = checks ]; then
  echo "=== state checklist green; --checks mode stops here ==="
  exit 0
fi

# Live turn.
if [ "$MODE" = repl ]; then
  echo "=== live REPL exchange (send 'summarize your role' then /quit) ==="
  BRIEF=$(mktemp)
  printf 'Say pong and describe yourself in one sentence.\n' > "$BRIEF"
  printf 'summarize your role\n/quit\n' | FM_ANTIGRAVITY_BIN="$AGENTAPI_BIN" "$REPL" "$BRIEF"
  rc=$?
  rm -f "$BRIEF"
  exit "$rc"
fi

echo "=== live batch turn (agentapi new-conversation flash) ==="
RESPONSE=$("$AGENTAPI_BIN" new-conversation --model=flash "Say pong and describe yourself in one sentence.")
echo "--- raw response ---"
printf '%s\n' "$RESPONSE"

if command -v jq >/dev/null 2>&1; then
  err=$(jq -r '.error // empty' <<<"$RESPONSE" 2>/dev/null)
  if [ -n "$err" ]; then
    echo "FAIL  agentapi returned an error:"
    printf '%s\n' "$err" >&2
    exit 4
  fi
  echo "--- extracted text (best-effort field cascade) ---"
  for path in '.response.text' '.response.content' '.response.message' \
              '.response.output_text' '.response.data' '.response.reply' \
              '.response.parts[0].text'; do
    if text=$(jq -er "$path // empty" <<<"$RESPONSE" 2>/dev/null) && [ -n "$text" ]; then
      printf 'field=%s\n%s\n' "$path" "$text"
      echo "=== smoke green: matched field '$path' ==="
      exit 0
    fi
  done
  echo "WARN  response has no matching field in the cascade; dumping .response object:"
  jq -r '.response' <<<"$RESPONSE"
  echo "=== smoke amber: live call succeeded but the field cascade needs widening ==="
  exit 5
fi

echo "=== smoke green (no jq installed to narrow response field; raw dumped above) ==="

#!/usr/bin/env bash
# antigravity-repl.sh - REPL wrapper that turns the batch `agentapi` CLI into
# a supervised-pane crewmate for firstmate.
#
# agentapi (Google Antigravity CLI, ~/.gemini/antigravity-cli/bin/agentapi) is
# a one-shot batch client: `new-conversation` prints one response JSON on
# stdout and exits. Firstmate's crewmate contract needs a long-lived pane
# whose stdout streams the current turn and whose stdin accepts follow-ups
# via fm-send. This wrapper composes those two shapes:
#
#   1. Read the brief from a file path (mirrors the __BRIEF__/__OPINPUT__
#      substitution the interactive adapters use, but agentapi does not accept
#      a stdin prompt - it takes the prompt as a positional argument).
#   2. Fire `agentapi new-conversation [--model=<tier>] "<brief>"`.
#   3. Parse the response JSON, extract the conversation_id (best-effort:
#      response.conversation_id | response.id | response.name), and stream
#      the human-readable response text to stdout so the operator sees it in
#      the tmux/herdr pane. On a JSON that parses but has no recognizable
#      text field, dump the whole .response object as JSON so no reply is
#      silently lost.
#   4. Enter an interactive-line REPL: for each stdin line (delivered by
#      fm-send), invoke `agentapi send-message <conversation_id> "<line>"`
#      and stream its response the same way. A blank line and the sentinels
#      /exit /quit end the pane cleanly (mirrors the muse/gemini exit contract).
#
# Exit codes:
#   0 - clean exit on /quit or stdin EOF after at least one turn completed.
#   2 - malformed brief or missing brief file.
#   3 - agentapi returned a response with a non-empty .error field on the
#       FIRST call - a fatal auth or LS-address error the operator has to
#       fix before any turn can complete. Subsequent turn failures are
#       printed but do NOT exit, so a transient RPC error does not kill an
#       otherwise live pane.
#   4 - could not extract a conversation_id from the first response - the
#       REPL cannot chain follow-ups without one, so refuse to enter the
#       loop rather than swallowing every send-message call.
#
# Environment:
#   FM_ANTIGRAVITY_BIN - override the resolved agentapi binary. When absent,
#                        default to $HOME/.gemini/antigravity-cli/bin/agentapi.
#   ANTIGRAVITY_LS_ADDRESS - required by agentapi itself; this wrapper does
#                        no additional preflight because fm-spawn owns the
#                        credential preflight (empty token / missing LS
#                        address / missing binary refusals live there).
#
# Usage:
#   antigravity-repl.sh <brief-file> [--model=<tier>]
set -u

BRIEF_FILE=${1:-}
if [ -z "$BRIEF_FILE" ] || [ ! -r "$BRIEF_FILE" ]; then
  echo "antigravity-repl: brief file '$BRIEF_FILE' is missing or unreadable" >&2
  exit 2
fi
shift || true

MODEL_ARG=
for arg in "$@"; do
  case "$arg" in
    --model=*) MODEL_ARG=$arg ;;
  esac
done

AGENTAPI_BIN=${FM_ANTIGRAVITY_BIN:-$HOME/.gemini/antigravity-cli/bin/agentapi}
if [ ! -x "$AGENTAPI_BIN" ]; then
  echo "antigravity-repl: agentapi binary not executable at '$AGENTAPI_BIN'" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "antigravity-repl: jq is required for response parsing but is not on PATH" >&2
  exit 2
fi

BRIEF=$(cat -- "$BRIEF_FILE")
if [ -z "$BRIEF" ]; then
  echo "antigravity-repl: brief file '$BRIEF_FILE' is empty" >&2
  exit 2
fi

# Print a response JSON's human-readable text if we can find it; otherwise
# dump the whole .response as pretty-printed JSON so the operator never
# loses a reply the wrapper failed to classify. Print exactly what a live
# turn produced - never a synthesized status line the classifier would
# confuse for the model's own words.
render_response() {
  local blob=$1
  local text
  # Try the most likely text carriers first; the exact field name has not
  # been live-verified because agentapi refuses every call under the empty
  # oauth-token placeholder that ships pre-consent. Broaden the alternation
  # rather than narrow it: any of these hits IS the model's reply. jq -e
  # returns 1 when the value is null/false, which lets us cascade.
  for path in '.response.text' '.response.content' '.response.message' \
              '.response.output_text' '.response.data' '.response.reply' \
              '.response.parts[0].text'; do
    if text=$(jq -er "$path // empty" <<<"$blob" 2>/dev/null) && [ -n "$text" ]; then
      printf '%s\n' "$text"
      return 0
    fi
  done
  # Nothing matched - dump .response as the fallback surface.
  jq -r '.response // .' <<<"$blob" 2>/dev/null || printf '%s\n' "$blob"
}

# Extract a conversation_id from the first response. Same broadening
# strategy as render_response: try the most likely field paths in order.
extract_conversation_id() {
  local blob=$1 val
  for path in '.response.conversation_id' '.response.id' '.response.name' \
              '.response.conversation.id' '.response.conversation_metadata.id'; do
    if val=$(jq -er "$path // empty" <<<"$blob" 2>/dev/null) && [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  done
  return 1
}

# Print any .error field as a single line so the operator sees why a call
# failed without hunting through raw JSON.
extract_error() {
  jq -r '.error // empty' <<<"$1" 2>/dev/null
}

# First turn: new-conversation seeded from the brief.
if [ -n "$MODEL_ARG" ]; then
  FIRST_RESPONSE=$("$AGENTAPI_BIN" new-conversation "$MODEL_ARG" "$BRIEF")
else
  FIRST_RESPONSE=$("$AGENTAPI_BIN" new-conversation "$BRIEF")
fi

FIRST_ERR=$(extract_error "$FIRST_RESPONSE")
if [ -n "$FIRST_ERR" ]; then
  echo "antigravity-repl: agentapi refused the first turn:" >&2
  printf '%s\n' "$FIRST_ERR" >&2
  echo "---" >&2
  printf '%s\n' "$FIRST_RESPONSE" >&2
  exit 3
fi

if ! CONVERSATION_ID=$(extract_conversation_id "$FIRST_RESPONSE"); then
  echo "antigravity-repl: could not extract a conversation_id from the first response - the REPL cannot chain follow-ups:" >&2
  printf '%s\n' "$FIRST_RESPONSE" >&2
  exit 4
fi

render_response "$FIRST_RESPONSE"

# REPL: fm-send delivers each follow-up as one stdin line. A blank line and
# the /exit /quit sentinels end the pane cleanly. `read -r` preserves
# backslashes so a code snippet the operator pastes does not get
# reinterpreted.
while IFS= read -r follow_up; do
  case "$follow_up" in
    ''|/exit|/quit) break ;;
  esac
  RESPONSE=$("$AGENTAPI_BIN" send-message "$CONVERSATION_ID" "$follow_up")
  ERR=$(extract_error "$RESPONSE")
  if [ -n "$ERR" ]; then
    # A transient RPC or per-turn error does NOT kill the pane: agentapi
    # can recover on the next send. Print the error to stderr so the
    # supervisor sees it in the pane transcript, then keep the loop alive.
    echo "antigravity-repl: agentapi returned an error on this turn:" >&2
    printf '%s\n' "$ERR" >&2
    continue
  fi
  render_response "$RESPONSE"
done

exit 0

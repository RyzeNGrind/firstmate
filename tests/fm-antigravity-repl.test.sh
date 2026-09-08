#!/usr/bin/env bash
# End-to-end tests for the antigravity-repl.sh REPL wrapper: response
# rendering, conversation_id extraction, first-turn-error refusal,
# per-turn-error resilience, and the /quit sentinel.
#
# agentapi cannot be exercised live at this landing because the operator's
# OAuth flow is still browser-interactive; these tests replace agentapi
# with a shell stub that returns known JSON shapes so the wrapper's
# parsing branches are provable without a Google-side dependency.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPL="$ROOT/bin/backends/antigravity-repl.sh"
TMP_ROOT=$(fm_test_tmproot fm-antigravity-repl)

if ! command -v jq >/dev/null 2>&1; then
  echo "1..0 # SKIP jq is required for antigravity REPL tests"
  exit 0
fi

# Build a fake agentapi shim that replays a scripted response sequence.
# Each call reads the next line from FM_FAKE_AGENTAPI_SCRIPT (one JSON blob
# per line) and prints it to stdout. When the script is exhausted, prints
# a terminal error blob so a stuck REPL fails loud instead of hanging.
make_fake_agentapi() {  # <case_dir> <script_lines...>
  local dir=$1; shift
  local script="$dir/agentapi-script.jsonl"
  : > "$script"
  local blob
  for blob in "$@"; do
    printf '%s\n' "$blob" >> "$script"
  done
  local bin="$dir/agentapi"
  cat > "$bin" <<'SH'
#!/usr/bin/env bash
# Record the invocation and reply with the next scripted line.
set -u
: "${FM_FAKE_AGENTAPI_SCRIPT:?script path unset}"
: "${FM_FAKE_AGENTAPI_LOG:?log path unset}"
printf 'agentapi %s\n' "$*" >> "$FM_FAKE_AGENTAPI_LOG"
# Extract the next line and rewrite the file without it (atomic).
line=$(head -1 "$FM_FAKE_AGENTAPI_SCRIPT" 2>/dev/null || true)
if [ -z "$line" ]; then
  printf '{"response": {}, "error": "agentapi test stub script exhausted"}\n'
  exit 0
fi
tail -n +2 "$FM_FAKE_AGENTAPI_SCRIPT" > "$FM_FAKE_AGENTAPI_SCRIPT.tmp"
mv "$FM_FAKE_AGENTAPI_SCRIPT.tmp" "$FM_FAKE_AGENTAPI_SCRIPT"
printf '%s\n' "$line"
SH
  chmod +x "$bin"
  printf '%s\n' "$bin"
}

# Run the REPL with a scripted fake agentapi and stdin.
run_repl() {  # <case_dir> <brief> <stdin_text> <bin>
  local case_dir=$1 brief=$2 stdin=$3 bin=$4
  local script="$case_dir/agentapi-script.jsonl"
  local log="$case_dir/agentapi-log"
  : > "$log"
  printf '%s' "$stdin" | FM_ANTIGRAVITY_BIN="$bin" \
    FM_FAKE_AGENTAPI_SCRIPT="$script" \
    FM_FAKE_AGENTAPI_LOG="$log" \
    "$REPL" "$brief" 2>&1
}

# --- happy path: first-turn text + one follow-up + /quit ---
test_repl_full_turn() {
  local case_dir bin brief out
  case_dir="$TMP_ROOT/happy"
  mkdir -p "$case_dir"
  brief="$case_dir/brief.md"
  printf 'summarize your role\n' > "$brief"
  bin=$(make_fake_agentapi "$case_dir" \
    '{"response": {"conversation_id": "conv-happy-1", "text": "pong from seed"}, "error": ""}' \
    '{"response": {"text": "pong from follow-up"}, "error": ""}')
  out=$(run_repl "$case_dir" "$brief" $'tell me more\n/quit\n' "$bin")
  assert_contains "$out" "pong from seed" \
    "REPL did not render the first-turn text field: $out"
  assert_contains "$out" "pong from follow-up" \
    "REPL did not render the follow-up text field: $out"
  # The wrapper must have dispatched exactly two calls: new-conversation +
  # one send-message. /quit ends the loop before a third call fires.
  local log
  log="$case_dir/agentapi-log"
  assert_grep 'new-conversation' "$log" "REPL did not fire new-conversation for the first turn"
  assert_grep 'send-message conv-happy-1' "$log" \
    "REPL did not reuse the conversation_id in send-message"
  pass "REPL renders both turns and reuses the captured conversation_id"
}

# --- response-shape cascade: try each field the wrapper knows about ---
test_repl_response_field_cascade() {
  local case_dir bin brief out path
  case_dir="$TMP_ROOT/cascade"
  mkdir -p "$case_dir"
  brief="$case_dir/brief.md"
  printf 'hi\n' > "$brief"
  # Each iteration seeds a single-turn conversation where the model reply
  # rides a different .response.<field>. The wrapper must find each one.
  local i=0
  for path in text content message output_text data reply; do
    i=$((i+1))
    bin=$(make_fake_agentapi "$case_dir" \
      "{\"response\": {\"conversation_id\": \"c-$path\", \"$path\": \"hit-via-$path\"}, \"error\": \"\"}")
    out=$(run_repl "$case_dir" "$brief" '' "$bin")
    assert_contains "$out" "hit-via-$path" \
      "REPL did not render .response.$path: $out"
  done
  # parts[0].text has a nested shape.
  bin=$(make_fake_agentapi "$case_dir" \
    '{"response": {"conversation_id": "c-parts", "parts": [{"text": "hit-via-parts"}]}, "error": ""}')
  out=$(run_repl "$case_dir" "$brief" '' "$bin")
  assert_contains "$out" "hit-via-parts" \
    "REPL did not render .response.parts[0].text: $out"
  pass "REPL response cascade covers text, content, message, output_text, data, reply, parts[0].text"
}

# --- conversation_id cascade: same broadening applies to the id path ---
test_repl_conversation_id_cascade() {
  local case_dir bin brief out
  case_dir="$TMP_ROOT/id-cascade"
  mkdir -p "$case_dir"
  brief="$case_dir/brief.md"
  printf 'x\n' > "$brief"
  # .id fallback (id not conversation_id): the wrapper must still resolve
  # a send-message target from it.
  bin=$(make_fake_agentapi "$case_dir" \
    '{"response": {"id": "cv-via-id", "text": "seed"}, "error": ""}' \
    '{"response": {"text": "reply-2"}, "error": ""}')
  out=$(run_repl "$case_dir" "$brief" $'more\n/quit\n' "$bin")
  assert_contains "$out" 'seed' "REPL missed seed reply on .id id path: $out"
  assert_contains "$out" 'reply-2' "REPL missed follow-up under .id id path: $out"
  assert_grep 'send-message cv-via-id' "$case_dir/agentapi-log" \
    "REPL did not extract conversation_id from .response.id"
  pass "REPL conversation_id cascade covers the .response.id fallback"
}

# --- first-turn error is fatal (exit 3) ---
test_repl_first_turn_error_exits() {
  local case_dir bin brief status
  case_dir="$TMP_ROOT/first-err"
  mkdir -p "$case_dir"
  brief="$case_dir/brief.md"
  printf 'x\n' > "$brief"
  bin=$(make_fake_agentapi "$case_dir" \
    '{"response": {}, "error": "test: auth denied"}')
  local out
  out=$(run_repl "$case_dir" "$brief" '' "$bin")
  status=$?
  expect_code 3 "$status" "first-turn error should exit 3 (got $status: $out)"
  # Nothing after the first call: no send-message was ever fired.
  assert_no_grep 'send-message' "$case_dir/agentapi-log" \
    "REPL fired send-message despite first-turn error"
  pass "REPL exits 3 on a first-turn error and does not enter the send loop"
}

# --- missing conversation_id in a successful-looking response is fatal (exit 4) ---
test_repl_missing_conversation_id_exits() {
  local case_dir bin brief status out
  case_dir="$TMP_ROOT/no-id"
  mkdir -p "$case_dir"
  brief="$case_dir/brief.md"
  printf 'x\n' > "$brief"
  bin=$(make_fake_agentapi "$case_dir" \
    '{"response": {"text": "reply-without-id"}, "error": ""}')
  out=$(run_repl "$case_dir" "$brief" '' "$bin")
  status=$?
  expect_code 4 "$status" "missing conversation_id should exit 4 (got $status: $out)"
  pass "REPL exits 4 when the first response has no extractable conversation_id"
}

# --- per-turn error is NOT fatal: the REPL keeps the pane alive ---
test_repl_per_turn_error_survives() {
  local case_dir bin brief out
  case_dir="$TMP_ROOT/per-turn-err"
  mkdir -p "$case_dir"
  brief="$case_dir/brief.md"
  printf 'x\n' > "$brief"
  bin=$(make_fake_agentapi "$case_dir" \
    '{"response": {"conversation_id": "cv-1", "text": "seed"}, "error": ""}' \
    '{"response": {}, "error": "test: transient rpc failure"}' \
    '{"response": {"text": "recovered"}, "error": ""}')
  out=$(run_repl "$case_dir" "$brief" $'first-follow\nsecond-follow\n/quit\n' "$bin")
  assert_contains "$out" 'seed' "REPL missed seed under per-turn-error scenario"
  assert_contains "$out" 'test: transient rpc failure' \
    "REPL did not surface the mid-turn error to stderr"
  assert_contains "$out" 'recovered' \
    "REPL did not survive the mid-turn error and dispatch the next send-message"
  pass "REPL keeps the pane alive across a transient per-turn error"
}

# --- brief file with special characters is delivered verbatim ---
test_repl_preserves_brief_with_special_chars() {
  local case_dir bin brief out
  case_dir="$TMP_ROOT/special"
  mkdir -p "$case_dir"
  brief="$case_dir/brief.md"
  # Quotes, backslashes, dollar signs, backticks - the shell-quote traps
  # any live-invoked wrapper needs to handle.
  printf 'brief with "quotes" and $vars and `backticks` and \\slashes\n' > "$brief"
  bin=$(make_fake_agentapi "$case_dir" \
    '{"response": {"conversation_id": "cv-x", "text": "seed"}, "error": ""}')
  out=$(run_repl "$case_dir" "$brief" '' "$bin")
  assert_contains "$out" 'seed' "REPL failed with a brief containing shell metacharacters: $out"
  # The invocation log should record the FULL brief text as the first-turn prompt.
  assert_grep 'brief with "quotes"' "$case_dir/agentapi-log" \
    "REPL did not deliver the brief verbatim (special chars stripped)"
  pass "REPL preserves briefs containing quotes, dollar signs, backticks, and backslashes"
}

# --- /exit sentinel is equivalent to /quit ---
test_repl_exit_sentinel() {
  local case_dir bin brief out
  case_dir="$TMP_ROOT/exit-sentinel"
  mkdir -p "$case_dir"
  brief="$case_dir/brief.md"
  printf 'x\n' > "$brief"
  bin=$(make_fake_agentapi "$case_dir" \
    '{"response": {"conversation_id": "cv-e", "text": "seed"}, "error": ""}')
  out=$(run_repl "$case_dir" "$brief" $'/exit\n' "$bin")
  assert_contains "$out" 'seed' "REPL missed seed before /exit"
  # No send-message ever fired: the /exit sentinel breaks the loop before
  # dispatching a real follow-up.
  assert_no_grep 'send-message' "$case_dir/agentapi-log" \
    "REPL dispatched send-message despite /exit sentinel"
  pass "REPL honors /exit as an equivalent quit sentinel"
}

# --- --model=<tier> reaches the first-turn command ---
test_repl_forwards_model_flag() {
  local case_dir bin brief out
  case_dir="$TMP_ROOT/model-flag"
  mkdir -p "$case_dir"
  brief="$case_dir/brief.md"
  printf 'x\n' > "$brief"
  bin=$(make_fake_agentapi "$case_dir" \
    '{"response": {"conversation_id": "cv-m", "text": "seed"}, "error": ""}')
  # Pass --model=pro after the brief file path (same shape fm-spawn uses).
  local script="$case_dir/agentapi-script.jsonl"
  local log="$case_dir/agentapi-log"
  : > "$log"
  local out
  out=$(FM_ANTIGRAVITY_BIN="$bin" FM_FAKE_AGENTAPI_SCRIPT="$script" FM_FAKE_AGENTAPI_LOG="$log" \
    "$REPL" "$brief" --model=pro <<<'')
  assert_grep '--model=pro' "$log" \
    "REPL did not forward --model=pro to the first-turn agentapi invocation"
  pass "REPL forwards --model=<tier> to the first-turn agentapi call"
}

test_repl_full_turn
test_repl_response_field_cascade
test_repl_conversation_id_cascade
test_repl_first_turn_error_exits
test_repl_missing_conversation_id_exits
test_repl_per_turn_error_survives
test_repl_preserves_brief_with_special_chars
test_repl_exit_sentinel
test_repl_forwards_model_flag

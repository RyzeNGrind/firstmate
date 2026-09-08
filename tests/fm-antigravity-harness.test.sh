#!/usr/bin/env bash
# Behavior tests for the antigravity (agentapi) scout adapter: harness
# detection, spawn launch shape, model-tier vocabulary, credential preflight,
# and ship + secondmate refusals.
#
# agentapi is the Antigravity CLI shipped at
# ~/.gemini/antigravity-cli/bin/agentapi (verified 2026-09-08). Its comm is
# the anchored name `agentapi`; detection therefore rides only the
# directly-named-executable arm of the ancestry walk. The batch shape means
# no interactive TUI stays alive; the adapter is scout-only at this landing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. Drop
# ambient markers so the asserted verdict does not depend on which harness
# launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-antigravity-harness)

# --- fakes ------------------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin token_ok
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  # A fake agentapi. Firstmate never runs this during the launch tests
  # (send-keys stops at logging the launch line), but tests that exercise
  # detection need a real executable in the parent chain. A shebang script's
  # comm is `bash`, so the stub execs a renamed real bash whose comm is
  # `agentapi` - the anchored comm arm ancestry detection looks for.
  mkdir -p "$dir/real"
  cp "$(command -v bash)" "$dir/real/agentapi"
  cat > "$fakebin/agentapi" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_HARNESS_RESULT:-}" ] || exit 0
exec "$FM_FAKE_AGENTAPI_REAL" -c 'result=$($FM_FAKE_HARNESS_PROBE); printf "%s" "$result" > "$FM_FAKE_HARNESS_RESULT"'
SH
  chmod +x "$fakebin/agentapi"

  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# Write a populated antigravity-oauth-token JSON file so the credential
# preflight passes. The precise shape mirrors what agentapi writes after a
# successful browser consent (access_token non-empty, refresh_token present,
# expiry_date in the future).
write_populated_token() {  # <path>
  cat > "$1" <<'JSON'
{
  "access_token": "ya29.fake-access-for-tests",
  "refresh_token": "1//fake-refresh-for-tests",
  "expiry_date": 9999999999000,
  "token_type": "Bearer"
}
JSON
}

# Write the pre-consent placeholder shape agentapi ships with before the
# browser OAuth flow ever runs: expiry=0 epoch, empty tokens.
write_empty_token() {  # <path>
  cat > "$1" <<'JSON'
{
  "access_token": "",
  "refresh_token": "",
  "expiry_date": 0,
  "token_type": ""
}
JSON
}

# Ship a fake agentapi binary the preflight can point at via
# FM_ANTIGRAVITY_BIN_OVERRIDE. It only needs to be executable; the launch
# tests never actually run it (send-keys captures the composed command).
make_fake_agentapi_bin() {  # <case_dir>
  local dir=$1 bin
  bin="$dir/agentapi-bin"
  cat > "$bin" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$bin"
  printf '%s\n' "$bin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id token bin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="antigravity-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  token="$case_dir/antigravity-oauth-token"
  write_populated_token "$token"
  bin=$(make_fake_agentapi_bin "$case_dir")
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id|$token|$bin"
}

make_fake_repl() {  # <case_dir>
  local dir=$1 repl
  repl="$dir/antigravity-repl.sh"
  cat > "$repl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repl"
  printf '%s\n' "$repl"
}

run_antigravity_spawn() {  # <home> <proj> <wt> <fakebin> <id> <token> <bin> [extra args...]
  # By default, run the SCOUT shape (batch new-conversation). Callers that
  # need the crewmate ship shape pass their own --scout override off and
  # supply a repl via FM_ANTIGRAVITY_REPL_OVERRIDE below.
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 token=$6 bin=$7
  shift 7
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_AGENTAPI_REAL="${fakebin%/fakebin}/real/agentapi" \
    FM_FAKE_HARNESS_PROBE="$HARNESS" \
    FM_ANTIGRAVITY_TOKEN_PATH="$token" \
    FM_ANTIGRAVITY_BIN_OVERRIDE="$bin" \
    ANTIGRAVITY_LS_ADDRESS="127.0.0.1:44444" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" antigravity --scout "$@" 2>&1
}

run_antigravity_ship_spawn() {  # <home> <proj> <wt> <fakebin> <id> <token> <bin> <repl> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 token=$6 bin=$7 repl=$8
  shift 8
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_AGENTAPI_REAL="${fakebin%/fakebin}/real/agentapi" \
    FM_FAKE_HARNESS_PROBE="$HARNESS" \
    FM_ANTIGRAVITY_TOKEN_PATH="$token" \
    FM_ANTIGRAVITY_BIN_OVERRIDE="$bin" \
    FM_ANTIGRAVITY_REPL_OVERRIDE="$repl" \
    ANTIGRAVITY_LS_ADDRESS="127.0.0.1:44444" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" antigravity "$@" 2>&1
}

# --- detection --------------------------------------------------------------

# A directly-named agentapi executable in the parent chain must be claimed
# by the anchored comm arm. The command substitution around the probe is
# load-bearing: a bare `-c <cmd>` lets the shell exec the probe in place,
# which REPLACES the agentapi process name the walk is supposed to find.
test_detects_named_process_ancestor() {
  local dir out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/agentapi"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$dir/agentapi" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = antigravity ] || fail "fm-harness.sh under process 'agentapi' reported '$out', expected antigravity"
  pass "antigravity is detected through a named agentapi ancestor"
}

# The comm match must be anchored: an unrelated command whose name merely
# CONTAINS agentapi is a different program and must not be claimed.
test_detection_is_anchored() {
  local dir bin out
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  for bin in agentapi-desktop notagentapi agentapid agentapi2; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != antigravity ] || fail "fm-harness.sh misdetected unrelated process '$bin' as antigravity"
  done
  pass "antigravity detection does not claim unrelated agentapi-containing commands"
}

# --- spawn ------------------------------------------------------------------

test_spawn_scout_launch_shape() {
  local rec case_dir home proj wt fakebin id token bin out status launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  out=$(run_antigravity_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$token" "$bin")
  status=$?
  expect_code 0 "$status" "antigravity scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=antigravity" "antigravity spawn did not report success"

  launch=$(cat "$home/launch.log")
  # The composed launch line invokes the resolved agentapi binary with the
  # new-conversation subcommand and delivers the brief through the same
  # encoded-launch-brief substitution the other adapters use.
  assert_contains "$launch" "$bin" "antigravity launch dropped the agentapi binary path"
  assert_contains "$launch" 'new-conversation' "antigravity launch did not use the new-conversation subcommand"
  assert_contains "$launch" 'encode launch-brief' "antigravity launch did not deliver the brief"
  # The launch is scout-shape (batch): no autonomy flag, no trust flag,
  # no interactive prompt flag - those all belong to interactive adapters.
  assert_not_contains "$launch" ' --yolo ' "antigravity launch invented a --yolo flag"
  assert_not_contains "$launch" ' --skip-trust ' "antigravity launch invented a workspace-trust flag"
  assert_not_contains "$launch" '--prompt-interactive' "antigravity launch used an interactive prompt flag"
  assert_grep 'harness=antigravity' "$home/state/$id.meta" "antigravity harness was not recorded in meta"
  assert_grep 'kind=scout' "$home/state/$id.meta" "antigravity spawn did not record scout kind"
  pass "antigravity scout launches with agentapi new-conversation and delivers the brief"
}

test_spawn_maps_model_tier_and_omits_effort() {
  local rec case_dir home proj wt fakebin id token bin launch
  # A supported tier is composed as --model=<tier> (equals form).
  rec=$(make_spawn_case model-tier)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  run_antigravity_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$token" "$bin" \
    --model flash --effort high >/dev/null \
    || fail "antigravity spawn with a supported model tier failed"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" '--model=flash' "antigravity spawn dropped the model tier"
  # No verified effort flag exists for antigravity: the tier IS the effort
  # axis, so the shared --effort flag must not reach the command.
  assert_not_contains "$launch" '--effort' "antigravity spawn invented an effort flag"
  assert_not_contains "$launch" '--reasoning-effort' "antigravity spawn invented a reasoning-effort flag"

  # An unsupported model id must NOT be passed through: the vocabulary is
  # gated so the pane never fires a call the server would reject with a
  # 400 the supervisor would misread as a wedged worker.
  rec=$(make_spawn_case model-unsupported)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  run_antigravity_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$token" "$bin" \
    --model gemini-2.5-flash >/dev/null \
    || fail "antigravity spawn with an unsupported model id failed"
  launch=$(cat "$home/launch.log")
  assert_not_contains "$launch" '--model=' "antigravity spawn passed an unsupported model id"

  # No --model when no model axis is chosen.
  rec=$(make_spawn_case model-default)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  run_antigravity_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$token" "$bin" >/dev/null \
    || fail "antigravity spawn without a model axis failed"
  launch=$(cat "$home/launch.log")
  assert_not_contains "$launch" '--model' "antigravity spawn invented a model when none was chosen"
  pass "antigravity maps supported tiers to --model=<tier>, drops others, and never invents effort"
}

# --- credential preflight ---------------------------------------------------

test_refuses_missing_token() {
  local rec case_dir home proj wt fakebin id token bin out status
  rec=$(make_spawn_case missing-token)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  rm -f "$token"
  out=$(run_antigravity_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$token" "$bin")
  status=$?
  [ "$status" -ne 0 ] || fail "antigravity spawn accepted a missing oauth token"
  assert_contains "$out" "oauth token missing or empty" \
    "antigravity refusal did not name the missing token"
  pass "antigravity refuses spawn when the oauth token file is missing"
}

test_refuses_empty_token() {
  local rec case_dir home proj wt fakebin id token bin out status
  rec=$(make_spawn_case empty-token)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  write_empty_token "$token"
  out=$(run_antigravity_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$token" "$bin")
  status=$?
  [ "$status" -ne 0 ] || fail "antigravity spawn accepted an empty access_token"
  assert_contains "$out" "empty access_token" \
    "antigravity refusal did not name the empty access_token"
  pass "antigravity refuses spawn when the oauth token holds an empty access_token"
}

test_refuses_missing_ls_address() {
  local rec case_dir home proj wt fakebin id token bin out status
  rec=$(make_spawn_case missing-ls)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  # Call fm-spawn directly (bypassing run_antigravity_spawn, which supplies
  # ANTIGRAVITY_LS_ADDRESS) and use `env -u` to guarantee the var is not
  # inherited from the outer test-runner environment either.
  out=$(env -u ANTIGRAVITY_LS_ADDRESS \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_ANTIGRAVITY_TOKEN_PATH="$token" \
    FM_ANTIGRAVITY_BIN_OVERRIDE="$bin" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" antigravity --scout 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "antigravity spawn accepted a missing ANTIGRAVITY_LS_ADDRESS"
  assert_contains "$out" "ANTIGRAVITY_LS_ADDRESS is not set" \
    "antigravity refusal did not name the missing LS address"
  pass "antigravity refuses spawn when ANTIGRAVITY_LS_ADDRESS is not set"
}

test_refuses_missing_binary() {
  local rec case_dir home proj wt fakebin id token bin out status
  rec=$(make_spawn_case missing-bin)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  rm -f "$bin"
  out=$(run_antigravity_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$token" "$bin")
  status=$?
  [ "$status" -ne 0 ] || fail "antigravity spawn accepted a missing agentapi binary"
  assert_contains "$out" "agentapi binary not found" \
    "antigravity refusal did not name the missing binary"
  pass "antigravity refuses spawn when the agentapi binary is not on the resolved path"
}

# --- kind refusals ----------------------------------------------------------

test_spawn_ship_uses_repl_wrapper() {
  local rec case_dir home proj wt fakebin id token bin repl out status launch
  rec=$(make_spawn_case ship)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  repl=$(make_fake_repl "$case_dir")
  out=$(run_antigravity_ship_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$token" "$bin" "$repl" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "antigravity ship spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=antigravity" "antigravity ship spawn did not report success"

  launch=$(cat "$home/launch.log")
  # The composed launch line invokes the REPL wrapper (crewmate shape), not
  # the raw batch new-conversation subcommand the scout shape uses.
  assert_contains "$launch" "$repl" "antigravity ship launch dropped the REPL wrapper path"
  assert_not_contains "$launch" 'new-conversation' \
    "antigravity ship launch reused the scout batch shape instead of the REPL wrapper"
  # FM_ANTIGRAVITY_BIN is forwarded so the REPL wrapper reaches the same
  # agentapi binary the preflight resolved rather than re-resolving from PATH.
  assert_contains "$launch" "FM_ANTIGRAVITY_BIN=" "antigravity ship launch did not forward FM_ANTIGRAVITY_BIN to the REPL"
  # The brief file path is passed positionally; the wrapper reads it with cat.
  assert_grep "$home/data/$id/brief.md" "$home/launch.log" \
    "antigravity ship launch did not pass the brief file path to the REPL"
  assert_grep 'harness=antigravity' "$home/state/$id.meta" "antigravity harness was not recorded in ship meta"
  assert_grep 'kind=ship' "$home/state/$id.meta" "antigravity ship spawn recorded the wrong kind"
  pass "antigravity ship launches through the REPL wrapper with the brief and forwarded binary"
}

test_spawn_ship_refuses_missing_repl_wrapper() {
  local rec case_dir home proj wt fakebin id token bin repl out status
  rec=$(make_spawn_case ship-no-repl)
  IFS='|' read -r case_dir home proj wt fakebin id token bin <<EOF
$rec
EOF
  # Point the override at a path that does not exist so the preflight
  # refuses rather than composing a launch that would fail at pane start.
  # --mode + --yolo are supplied because a ship spawn requires them; the
  # test is proving the REPL preflight fires AFTER those universal ship
  # gates, not that a missing --mode is the cause of the refusal.
  repl="$case_dir/nonexistent-repl.sh"
  out=$(run_antigravity_ship_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$token" "$bin" "$repl" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "antigravity ship spawn accepted a missing REPL wrapper"
  assert_contains "$out" "antigravity REPL wrapper not executable" \
    "antigravity ship refusal did not name the missing REPL wrapper"
  pass "antigravity ship refuses spawn when the REPL wrapper is not executable"
}

test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status bin token
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="antigravity-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  token="$case_dir/antigravity-oauth-token"
  write_populated_token "$token"
  bin=$(make_fake_agentapi_bin "$case_dir")
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_ANTIGRAVITY_TOKEN_PATH="$token" FM_ANTIGRAVITY_BIN_OVERRIDE="$bin" \
    ANTIGRAVITY_LS_ADDRESS="127.0.0.1:44444" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" antigravity --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "antigravity was accepted as a secondmate harness"
  assert_contains "$out" "scout adapter only" \
    "antigravity secondmate refusal did not explain the boundary"
  pass "antigravity is refused as a secondmate harness"
}

# --- busy record contract ---------------------------------------------------

# antigravity is batch-shape and records nothing firstmate trusts, so it must
# trust no record source. A trusted source with no writer would seed a busy
# record nothing could ever settle.
test_antigravity_trusts_no_record_sources() {
  local out
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_sources_for_harness antigravity
  )
  [ -z "$out" ] || fail "antigravity trusts record sources it has no writer for: '$out'"
  pass "antigravity trusts no busy record source"
}

test_detects_named_process_ancestor
test_detection_is_anchored
test_spawn_scout_launch_shape
test_spawn_maps_model_tier_and_omits_effort
test_refuses_missing_token
test_refuses_empty_token
test_refuses_missing_ls_address
test_refuses_missing_binary
test_spawn_ship_uses_repl_wrapper
test_spawn_ship_refuses_missing_repl_wrapper
test_spawn_refuses_secondmate
test_antigravity_trusts_no_record_sources

#!/usr/bin/env bash
# Behavior tests for the gemini (Gemini CLI) crewmate adapter: harness
# detection, spawn launch shape, model-flag composition, foreign-marker
# hygiene, the secondmate refusal, and the empty busy-source contract.
#
# gemini is a Node CLI (verified, gemini 0.58.0): the launcher at
# /usr/local/bin/gemini is a `#!/usr/bin/env node` script, so the live process
# comm is `node` with the script path in argv. Detection therefore has to work
# through BOTH the bare-interpreter args fallback and a directly named gemini
# executable, and both shapes are pinned here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. gemini is
# marker-less for detection purposes (its GEMINI_CLI=1 child marker is not
# promoted; see fm-harness.sh), so an inherited Cursor/Claude/Pi/Grok marker
# would outrank the gemini ancestor these detection cases launch. Drop the
# ambient markers so the asserted verdict does not depend on which harness
# launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-gemini-harness)

# --- spawn scaffolding ------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
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
        if [ "${FM_FAKE_EXECUTE_GEMINI_LAUNCH:-}" = 1 ]; then
          case "$arg" in
            *gemini*) (cd "$FM_FAKE_PANE_PATH" && bash -c "$arg") ;;
          esac
        fi
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
  # The fake gemini used by the marker-hygiene case. A shebang script's comm is
  # `bash`, not the script name, so the stub execs a renamed REAL bash binary
  # whose comm is `gemini` (the anchored comm arm) and runs the probe as its
  # forked child - the TUI-parent/tool-child shape ancestry detection needs.
  mkdir -p "$dir/real"
  cp "$(command -v bash)" "$dir/real/gemini"
  cat > "$fakebin/gemini" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_HARNESS_RESULT:-}" ] || exit 0
exec "$FM_FAKE_GEMINI_REAL" -c 'result=$($FM_FAKE_HARNESS_PROBE); printf "%s" "$result" > "$FM_FAKE_HARNESS_RESULT"'
SH
  chmod +x "$fakebin/gemini"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="gemini-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_gemini_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_GEMINI_REAL="${fakebin%/fakebin}/real/gemini" \
    FM_FAKE_HARNESS_PROBE="$HARNESS" \
    FM_FAKE_EXECUTE_GEMINI_LAUNCH="${FM_FAKE_EXECUTE_GEMINI_LAUNCH:-}" \
    FM_FAKE_HARNESS_RESULT="${FM_FAKE_HARNESS_RESULT:-}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" gemini "$@" 2>&1
}

# --- detection --------------------------------------------------------------

# A directly named gemini executable in the parent chain must be claimed by
# the comm arm. The command substitution around the probe is load-bearing: a
# bare `-c <cmd>` lets the shell exec the probe in place, which REPLACES the
# gemini process name the walk is supposed to find. The real CLI keeps its TUI
# process alive and runs tools as children, so forcing a fork is what
# reproduces that shape.
test_detects_named_process_ancestor() {
  local dir out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/gemini"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$dir/gemini" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = gemini ] || fail "fm-harness.sh under process 'gemini' reported '$out', expected gemini"
  pass "gemini is detected through a named gemini ancestor"
}

# The real installed shape (verified, gemini 0.58.0): comm is `node` and the
# launcher script path carries `gemini` in argv, so the bare-interpreter args
# fallback must claim it.
test_detects_node_script_ancestor() {
  local dir out
  dir="$TMP_ROOT/detect-node"
  mkdir -p "$dir/bin"
  cp "$(command -v bash)" "$dir/bin/node"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$dir/bin/node" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"" node /usr/local/bin/gemini)
  [ "$out" = gemini ] || fail "fm-harness.sh under 'node .../gemini' reported '$out', expected gemini"
  pass "gemini is detected through the node launcher-script args fallback"
}

# The comm match must be anchored: an unrelated command whose name merely
# CONTAINS gemini is a different program and must not be claimed.
test_detection_is_anchored() {
  local dir bin out
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  for bin in gemini-desktop notgemini geminid gemini2; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != gemini ] || fail "fm-harness.sh misdetected unrelated process '$bin' as gemini"
  done
  pass "gemini detection does not claim unrelated gemini-containing commands"
}

test_spawn_clears_inherited_foreign_harness_markers() {
  local rec case_dir home proj wt fakebin id result out status
  rec=$(make_spawn_case inherited-markers)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  result="$case_dir/harness-result"
  out=$(CLAUDECODE=1 PI_CODING_AGENT=true GROK_AGENT=1 FM_PI_HARNESS=pi-signed \
    CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    FM_FAKE_EXECUTE_GEMINI_LAUNCH=1 FM_FAKE_HARNESS_RESULT="$result" \
    run_gemini_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "gemini spawn from a marked backend should succeed: $out"
  [ -f "$result" ] || fail "the generated gemini launch never executed its harness probe"
  [ "$(cat "$result")" = gemini ] \
    || fail "gemini worker inherited a foreign harness identity: $(cat "$result")"
  pass "gemini launch clears foreign harness markers before ancestry detection"
}

# --- spawn ------------------------------------------------------------------

test_spawn_launch_shape() {
  local rec case_dir home proj wt fakebin id out status launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_gemini_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "gemini spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=gemini" "gemini spawn did not report success"

  launch=$(cat "$home/launch.log")
  # --yolo is what makes a crewmate pane viable at all: without it gemini
  # holds every tool call for approval.
  assert_contains "$launch" ' --yolo ' "gemini launch omitted --yolo"
  # --skip-trust is the fresh-worktree control: every task worktree is a path
  # gemini has never seen, and without it the workspace-trust dialog blocks
  # the pane (same trap as cursor's --trust).
  assert_contains "$launch" ' --skip-trust ' "gemini launch omitted --skip-trust"
  # The brief rides --prompt-interactive so gemini executes it and then stays
  # in the supervised interactive session; plain -p would exit headless.
  assert_contains "$launch" '--prompt-interactive' \
    "gemini launch did not use the execute-then-stay-interactive prompt flag"
  assert_contains "$launch" 'encode launch-brief' "gemini launch did not deliver the brief"
  assert_grep 'harness=gemini' "$home/state/$id.meta" "gemini harness was not recorded in meta"
  pass "gemini spawn launches with autonomy, workspace trust, and an interactive brief"
}

test_spawn_maps_model_and_omits_effort() {
  local rec case_dir home proj wt fakebin id launch
  rec=$(make_spawn_case model)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_gemini_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --model gemini-2.5-flash --effort high >/dev/null \
    || fail "gemini spawn with model and effort failed"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "-m 'gemini-2.5-flash'" "gemini spawn dropped the model axis"
  # gemini has no verified reasoning-effort flag; the requested axis stays in
  # task metadata but never reaches the launch command.
  assert_not_contains "$launch" '--effort' "gemini spawn invented an effort flag"
  assert_not_contains "$launch" '--reasoning-effort' "gemini spawn invented a reasoning-effort flag"

  rec=$(make_spawn_case model-default)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_gemini_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "gemini spawn without a model axis failed"
  launch=$(cat "$home/launch.log")
  assert_not_contains "$launch" ' -m ' "gemini spawn invented a model when none was chosen"
  pass "gemini maps the model axis to -m and never invents an effort flag"
}

# gemini's AfterAgent hook dialect is bundle-verified but its firing has never
# been live-verified (gemini 0.58.0, 2026-09-07), so no turn-end wiring and no
# busy record may be produced for it. A seeded record with no verified writer
# could never be settled.
test_spawn_writes_no_turnend_wiring_or_busy_record() {
  local rec case_dir home proj wt fakebin id
  rec=$(make_spawn_case no-wiring)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_gemini_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "gemini spawn failed"
  assert_absent "$home/state/$id.busy-gen" "gemini spawn armed a busy record it can never clear"
  assert_absent "$wt/.gemini/settings.json" \
    "gemini spawn injected unverified hook wiring into the worktree"
  pass "gemini spawn arms no busy record and injects no unverified hook wiring"
}

# gemini has no primary supervision protocol verified, so a secondmate on
# gemini could never arm a supervision cycle.
test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="gemini-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" gemini --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "gemini was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" \
    "gemini secondmate refusal did not explain the boundary"
  pass "gemini is refused as a secondmate harness"
}

# gemini records nothing firstmate trusts, so it must trust no record source.
# A trusted source with no writer would seed a busy record that nothing could
# ever settle.
test_gemini_trusts_no_record_sources() {
  local out
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_sources_for_harness gemini
  )
  [ -z "$out" ] || fail "gemini trusts record sources it has no writer for: '$out'"
  pass "gemini trusts no busy record source"
}

test_detects_named_process_ancestor
test_detects_node_script_ancestor
test_detection_is_anchored
test_spawn_clears_inherited_foreign_harness_markers
test_spawn_launch_shape
test_spawn_maps_model_and_omits_effort
test_spawn_writes_no_turnend_wiring_or_busy_record
test_spawn_refuses_secondmate
test_gemini_trusts_no_record_sources

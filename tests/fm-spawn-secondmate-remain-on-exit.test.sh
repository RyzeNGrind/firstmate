#!/usr/bin/env bash
# tests/fm-spawn-secondmate-remain-on-exit.test.sh - regression for the
# tmux remain-on-exit setting fm-spawn.sh applies to secondmate supervisor
# windows.
#
# The defect this test guards against: a captain's tmux without the
# remain-on-exit default causes a secondmate supervisor window to close the
# instant Claude exits between turns, which makes the fleet's liveness read
# classify the window as missing and produces false blocked detections.
# fm-spawn.sh must emit `tmux set-option -t <window> remain-on-exit on` on the
# supervisor window it creates for KIND=secondmate, and it must NOT emit it for
# any other KIND (crewmate/ship windows exit at task completion by design and
# would linger indefinitely with remain-on-exit on).
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-window-persist)
export FM_BACKEND=tmux
SPAWN="$ROOT/bin/fm-spawn.sh"

# tmux commands are captured through the argv-recording fake in
# secondmate-helpers.sh; the fm-spawn.sh -> tmux boundary is the observable
# contract we assert on.

# A secondmate supervisor window must have remain-on-exit switched on.
test_secondmate_supervisor_window_gets_remain_on_exit_on() {
  local case_dir home sub sub_abs fakebin log
  case_dir="$TMP_ROOT/positive"
  home="$case_dir/main-home"
  sub="$case_dir/design-home"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$home/config"
  mkdir -p "$sub/data"
  mark_firstmate_home "$sub"
  printf 'design\n' > "$sub/.fm-secondmate-home"
  printf '# Charter\n\nHandled work.\n' > "$sub/data/charter.md"
  sub_abs=$(cd "$sub" && pwd -P)
  printf -- '- design - test route (home: %s; scope: test scope; projects: ; added 2026-07-30)\n' \
    "$sub_abs" > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$case_dir/fake")
  make_fake_no_mistakes "$case_dir/fake" >/dev/null
  log="$case_dir/fake/tmux.log"
  : > "$log"

  PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$case_dir/fake/pane.txt" \
    "$SPAWN" design "$sub" codex --secondmate >/dev/null 2>&1 \
    || fail "secondmate launch did not succeed"

  # The set-option call must target the freshly created window with
  # remain-on-exit on. Any argv with those tokens on the same line is what
  # tmux would receive, so this is the exact contract at the fm-spawn.sh ->
  # tmux boundary.
  grep -E '^set-option (-t [^ ]* )?remain-on-exit on' "$log" >/dev/null \
    || fail "fm-spawn.sh did not set remain-on-exit=on on the secondmate window"$'\n'"log:"$'\n'"$(cat "$log")"

  # And the call must sequence AFTER the window was created (otherwise it
  # would target the wrong window or fail on a nonexistent id).
  new_line=$(grep -n '^new-window ' "$log" | head -1 | cut -d: -f1)
  opt_line=$(grep -n '^set-option .*remain-on-exit on' "$log" | head -1 | cut -d: -f1)
  [ -n "$new_line" ] || fail "secondmate launch never created its tmux window"
  [ -n "$opt_line" ] || fail "remain-on-exit was not set on the secondmate window"
  [ "$opt_line" -gt "$new_line" ] \
    || fail "remain-on-exit was set before the window was created"

  pass "secondmate launch sets remain-on-exit=on on its supervisor window after creating it"
}

# A default (ship) launch must NOT emit remain-on-exit on: its window is meant
# to close when the task ends, and a stray remain-on-exit would keep dead task
# windows lingering forever.
test_ship_window_does_not_get_remain_on_exit_on() {
  local case_dir home proj wt fakebin log id
  case_dir="$TMP_ROOT/negative"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=ship-y1
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a default (ship) launch so remain-on-exit is verifiably not applied.

## Firstmate spec
Run through the create-window path with KIND=ship and no supervisor decoration.
EOF
  touch "$home/state/.last-watcher-beat"

  fakebin=$(fm_fakebin "$case_dir/fake")
  # A fake tmux that records every argv and always exits 0. pane_current_path
  # returns the settled worktree so the settle loop confirms on the second
  # read; display-message returns the ambient session name. This mirrors the
  # fm-spawn-worktree-settle test setup for a default (ship) launch, with the
  # single addition that unknown commands are recorded and exit 0 (the
  # secondmate suite fake already logs set-option; a ship suite has never
  # needed that recognition).
  log="$case_dir/tmux.log"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$wt"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-option|set-window-option|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  : > "$log"

  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off >/dev/null 2>&1 \
    || fail "ship launch did not succeed"

  # The window must have been created (proves the code path was exercised).
  grep -E '^new-window ' "$log" >/dev/null \
    || fail "ship launch never created its tmux window (code path was not exercised)"$'\n'"log:"$'\n'"$(cat "$log")"

  # And no remain-on-exit option was applied to it. Match only argv that starts
  # with `set-option` (or `set-window-option`) at the beginning of a recorded
  # line, so an incidental match on a temp-dir name in another argv cannot
  # trigger a false positive.
  if grep -E '^set(-window)?-option .*remain-on-exit' "$log" >/dev/null; then
    fail "ship launch wrongly set remain-on-exit; log:"$'\n'"$(cat "$log")"
  fi

  pass "default (ship) launch creates its window without remain-on-exit"
}

test_secondmate_supervisor_window_gets_remain_on_exit_on
test_ship_window_does_not_get_remain_on_exit_on

echo "# all fm-spawn-secondmate-remain-on-exit tests passed"

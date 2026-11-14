#!/usr/bin/env bash
# Regression test for jq "Argument list too long" when passing large JSON through argv.
# The fix uses file transport (--slurpfile) instead of argv (--argjson) for large JSON.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-large-json)

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

generate_large_backlog() {
  local home=$1 count=${2:-100}
  # Generate large backlog with many tasks to exceed typical argv limits (~128KB on most systems)
  {
    printf '%s\n' '# Backlog' '' '## In flight'
    for i in $(seq 1 "$count"); do
      printf '%s\n' "- [ ] task-$(printf '%04d' "$i") - Large backlog item $i (repo: test) (kind: ship)"
    done
    printf '%s\n' '' '## Queued'
    for i in $(seq $((count + 1)) $((count + 50))); do
      printf '%s\n' "- [ ] task-$(printf '%04d' "$i") - Queued item $i (repo: test) (kind: ship)"
    done
  } > "$home/data/backlog.md"
}

generate_large_task_meta() {
  local home=$1 count=${2:-100}
  # Generate multiple task metadata files with large content
  for idx in $(seq 1 "$count"); do
    mkdir -p "$home/state"
    task_id="task-$(printf '%04d' "$idx")"
    jq -n --arg id "$task_id" \
      --arg pr_url "https://github.com/test/repo/pull/$idx" \
      --arg pr_head "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" '
      {
        kind: "ship",
        harness: "claude",
        pr: $pr_url,
        pr_head: $pr_head,
        project: "test-project-with-very-long-name",
        worktree: "/very/long/path/to/worktree/that/makes/this/even/longer",
        home: "/another/very/long/path/to/home/directory"
      }' > "$home/state/$task_id.meta" || return 1
  done
}

test_contribution_input_with_large_json() {
  local home
  home=$(new_home large-json)
  generate_large_backlog "$home" 200 || fail "backlog generation failed"
  generate_large_task_meta "$home" 50 || fail "task metadata generation failed"

  # Invoke fm-fleet-snapshot.sh with --contribution-input and large JSON
  local output
  output=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input 2>&1) \
    || {
      # Check if the error is specifically "Argument list too long"
      if printf '%s' "$output" | grep -q "Argument list too long"; then
        fail "jq failed with 'Argument list too long' - file transport not used"
      fi
      fail "contribution-input failed: $output"
    }

  # Verify output is valid JSON with expected structure
  printf '%s' "$output" | jq -e '
    .backlog != null and .tasks != null and
    (.backlog | has("path", "present", "records")) and
    (.tasks | type == "array")' >/dev/null \
    || fail "output JSON structure invalid: $output"

  pass 'large JSON passed through file transport without argv limit error'
}

test_backlog_exceeds_argv_limit() {
  local home
  home=$(new_home backlog-limit)
  # Generate extremely large backlog to ensure it exceeds typical argv limit
  generate_large_backlog "$home" 500 || fail "large backlog generation failed"

  local output
  output=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input 2>&1) \
    || {
      if printf '%s' "$output" | grep -q "Argument list too long"; then
        fail "large backlog caused argv overflow - transport method failed"
      fi
      fail "contribution-input with large backlog failed: $output"
    }

  # Verify output structure
  printf '%s' "$output" | jq -e '.backlog.records | length > 400' >/dev/null \
    || fail "output should contain many backlog records"

  pass 'very large backlog handled through file transport'
}

# Run tests
test_contribution_input_with_large_json
test_backlog_exceeds_argv_limit

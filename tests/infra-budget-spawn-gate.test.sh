#!/usr/bin/env bash
# Behavior tests for the infra-budget spawn gate in fm-spawn.sh.
#
# The spawn gate enforces two infra-budget ceilings from /etc/nixify/infra-budgets.json
# (written by cells/modules/infra-budgets.nix when enabled):
#   1. max_concurrent_agents ceiling against live task count
#   2. 15% disk floor against declared disk_gb
#
# The gate is skipped for relaunches and secondmate spawns, and is silent
# when the file is absent (hosts without infra-budgets.nix are unaffected).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot infra-budget-spawn-gate)
export FM_BACKEND=tmux

# Clear ambient firstmate overrides so the behavior test owns its environment.
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# --- Helpers ----------------------------------------------------------------

# make_home <dir> <task-count> creates a firstmate home with <task-count> live
# ordinary task records (state/*.meta files, kind != secondmate).
make_home() {
  local dir=$1 count=$2 i
  mkdir -p "$dir/state" "$dir/data"
  for ((i = 1; i <= count; i++)); do
    echo "kind=ship" > "$dir/state/task-$i.meta"
  done
}

# make_budget_file <path> <json> creates the budget JSON file.
make_budget_file() {
  local path=$1 json=$2
  mkdir -p "$(dirname "$path")"
  echo "$json" > "$path"
}

# --- Tests ------------------------------------------------------------------

# When the budget file is absent, the gate is skipped silently and spawn proceeds
# to the next check (which fails because there's no brief). The absence is not
# an error.
test_gate_silent_when_file_absent() {
  local home="$TMP_ROOT/absent-budget-home"
  make_home "$home" 0

  # Verify the file does not exist and spawn fails at brief check, not budget check.
  local out status
  out=$(INFRA_BUDGETS_FILE="$home/nonexistent/budget.json" \
    FM_HOME="$home" run_spawn test-absent-budget projects/none --mode no-mistakes --yolo off 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn with missing brief should fail"
  printf '%s\n' "$out" | grep -F "infra budget" >/dev/null \
    && fail "gate was not skipped when budget file is absent"
  printf '%s\n' "$out" | grep -F "has no brief" >/dev/null \
    || fail "spawn did not reach the expected next check"

  pass "gate is silent when budget file is absent"
}

# When the budget file exists and declares max_concurrent_agents, spawning is
# refused when the ceiling is already reached.
test_concurrency_ceiling_enforced() {
  local home="$TMP_ROOT/concur-ceiling-home"
  local budget_file="$home/.budgets.json"
  make_home "$home" 2
  make_budget_file "$budget_file" '{"max_concurrent_agents": 2}'

  # Spawn a new task when the ceiling is already at 2 live tasks.
  local out status
  out=$(INFRA_BUDGETS_FILE="$budget_file" \
    FM_HOME="$home" run_spawn test-concur-ceiling projects/none --mode no-mistakes --yolo off 2>&1)
  status=$?

  [ "$status" -eq 1 ] || fail "spawn should be refused when ceiling is reached"
  printf '%s\n' "$out" | grep -F "infra budget ceiling" >/dev/null \
    || fail "spawn refusal did not mention infra budget ceiling"
  printf '%s\n' "$out" | grep -F "max_concurrent_agents=2" >/dev/null \
    || fail "spawn refusal did not name the budget limit"
  printf '%s\n' "$out" | grep -F "live_tasks=2" >/dev/null \
    || fail "spawn refusal did not name the live task count"
  printf '%s\n' "$out" | grep -F "wait for a running task to finish" >/dev/null \
    || fail "spawn refusal did not provide guidance"

  pass "concurrency ceiling enforced when max_concurrent_agents is reached"
}

# When max_concurrent_agents is declared but not yet reached, spawn is allowed.
test_concurrency_ceiling_not_yet_reached() {
  local home="$TMP_ROOT/concur-ok-home"
  local budget_file="$home/.budgets.json"
  make_home "$home" 1
  make_budget_file "$budget_file" '{"max_concurrent_agents": 2}'

  # Spawn a new task when only 1 task is live; ceiling is 2.
  local out status
  out=$(INFRA_BUDGETS_FILE="$budget_file" \
    FM_HOME="$home" run_spawn test-concur-ok projects/none --mode no-mistakes --yolo off 2>&1)
  status=$?

  # Spawn still fails because there's no brief, but NOT because of the budget gate.
  [ "$status" -ne 0 ] || fail "spawn with missing brief should fail"
  printf '%s\n' "$out" | grep -F "infra budget ceiling" >/dev/null \
    && fail "concurrency gate wrongly refused a spawn below the ceiling"
  printf '%s\n' "$out" | grep -F "has no brief" >/dev/null \
    || fail "spawn did not reach the expected next check"

  pass "spawn allowed when live task count is below ceiling"
}

# When max_concurrent_agents is malformed (non-numeric, empty, etc.), it is
# skipped silently.
test_malformed_max_agents_ignored() {
  local home="$TMP_ROOT/malformed-agents-home"
  local budget_file="$home/.budgets.json"
  make_home "$home" 2

  # Non-numeric max_concurrent_agents should be ignored.
  make_budget_file "$budget_file" '{"max_concurrent_agents": "not-a-number"}'
  local out status
  out=$(INFRA_BUDGETS_FILE="$budget_file" \
    FM_HOME="$home" run_spawn test-malformed-agents projects/none --mode no-mistakes --yolo off 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn with missing brief should fail"
  printf '%s\n' "$out" | grep -F "infra budget ceiling" >/dev/null \
    && fail "malformed max_agents was not ignored"

  pass "malformed max_concurrent_agents is ignored"
}

# When the budget file declares disk_gb, a spawn is refused if available disk
# space is below 15% of the declared budget.
test_disk_floor_enforced() {
  local home="$TMP_ROOT/disk-floor-home"
  local budget_file="$home/.budgets.json"
  make_home "$home" 0

  # Declare a 1000G budget, floor = 150G. This will fail on most systems because
  # 150G is not available. For testing, we just verify the message format; the
  # actual disk check uses df -k / which reads the real filesystem.
  make_budget_file "$budget_file" '{"disk_gb": 1000.0}'

  local out status
  out=$(INFRA_BUDGETS_FILE="$budget_file" \
    FM_HOME="$home" run_spawn test-disk-floor projects/none --mode no-mistakes --yolo off 2>&1)
  status=$?

  # On a system with less than 150G free on /, this spawn should be refused.
  # If the test system has more, spawn continues to the next check (brief).
  if printf '%s\n' "$out" | grep -F "disk headroom" >/dev/null; then
    printf '%s\n' "$out" | grep -F "disk_gb=1000" >/dev/null \
      || fail "disk floor refusal did not name the budget limit"
    printf '%s\n' "$out" | grep -F "floor=" >/dev/null \
      || fail "disk floor refusal did not name the floor value"
    printf '%s\n' "$out" | grep -F "free disk space before spawning" >/dev/null \
      || fail "disk floor refusal did not provide guidance"
  else
    # Spawn reached the brief check instead, which is also ok for this test.
    printf '%s\n' "$out" | grep -F "has no brief" >/dev/null \
      || fail "spawn did not reach the expected next check when disk is available"
  fi

  pass "disk floor checked when disk_gb is declared"
}

# The gate is skipped for relaunch spawns.
test_gate_skipped_for_relaunch() {
  local home="$TMP_ROOT/relaunch-skip-home"
  local budget_file="$home/.budgets.json"
  make_home "$home" 2
  make_budget_file "$budget_file" '{"max_concurrent_agents": 1}'

  # A relaunch should not be refused by the budget gate, even though the
  # ceiling would be reached. The relaunch still fails, but at a different check.
  local out status
  out=$(INFRA_BUDGETS_FILE="$budget_file" \
    FM_HOME="$home" run_spawn test-relaunch-skip --relaunch 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "relaunch with missing metadata should fail"
  printf '%s\n' "$out" | grep -F "infra budget ceiling" >/dev/null \
    && fail "budget gate was not skipped for relaunch"
  printf '%s\n' "$out" | grep -F "does not exist" >/dev/null \
    || fail "relaunch did not fail at the expected check"

  pass "budget gate is skipped for relaunch spawns"
}

# The gate is skipped for secondmate spawns.
test_gate_skipped_for_secondmate() {
  local home="$TMP_ROOT/secondmate-skip-home"
  local budget_file="$home/.budgets.json"
  make_home "$home" 2
  make_budget_file "$budget_file" '{"max_concurrent_agents": 1}'

  # A secondmate spawn should not be refused by the budget gate, even though
  # the ceiling would be reached.
  local out status
  out=$(INFRA_BUDGETS_FILE="$budget_file" \
    FM_HOME="$home" run_spawn test-secondmate-skip /tmp/nonexistent --secondmate 2>&1)
  status=$?

  [ "$status" -ne 0 ] || true # secondmate spawn may fail, but not on budget
  printf '%s\n' "$out" | grep -F "infra budget ceiling" >/dev/null \
    && fail "budget gate was not skipped for secondmate spawn"

  pass "budget gate is skipped for secondmate spawns"
}

# Run all tests
test_gate_silent_when_file_absent
test_concurrency_ceiling_enforced
test_concurrency_ceiling_not_yet_reached
test_malformed_max_agents_ignored
test_disk_floor_enforced
test_gate_skipped_for_relaunch
test_gate_skipped_for_secondmate

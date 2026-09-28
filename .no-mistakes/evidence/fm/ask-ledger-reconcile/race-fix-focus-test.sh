#!/usr/bin/env bash
# Isolates the exact assertion changed in tests/fm-remote-job.test.sh:275-282.
# Uses a mock fm_remote_job_process_start that simulates the three critical
# outcomes: process gone, PID reused (different start time), same process alive.
set -u

pass_count=0
fail_count=0
fail() { printf 'not ok - %s\n' "$*"; fail_count=$((fail_count + 1)); }
pass() { printf 'ok - %s\n' "$*"; pass_count=$((pass_count + 1)); }

run_check() {  # <old_start> <cur_start> should evaluate the fix assertion
  local OLD_SUPERVISOR_START=$1 _cur_sup_start=$2
  if [ -z "$_cur_sup_start" ] || [ "$_cur_sup_start" != "$OLD_SUPERVISOR_START" ]; then
    return 0  # passed the assertion
  fi
  return 1  # fail: same process still alive
}

# Case 1: supervisor process really gone (ps returns nothing).
if run_check "Mon Sep 28 10:00:00 2026" ""; then
  pass "reports pass when supervisor group is gone"
else
  fail "case 1: gone process was reported alive"
fi

# Case 2: PID reused by an unrelated process (different start time).
# This is the race the fix addresses - old kill -0 would false-positive here.
if run_check "Mon Sep 28 10:00:00 2026" "Mon Sep 28 10:05:00 2026"; then
  pass "reports pass when PID is reused by a different process (race fix)"
else
  fail "case 2: PID reuse case incorrectly reported as leak"
fi

# Case 3: same supervisor still alive (same start time) - should fail.
if run_check "Mon Sep 28 10:00:00 2026" "Mon Sep 28 10:00:00 2026"; then
  fail "case 3: same alive supervisor was NOT detected as leak"
else
  pass "reports fail when same supervisor is still alive"
fi

printf '\nResults: %d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]

#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/git-config-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}

# herdr_skip_if_treehouse_worktree_broken <spawn-stderr-file>
# Real-herdr tests that drive bin/fm-spawn.sh depend on `treehouse get` moving
# the pane's cwd into an isolated worktree within 60s. On hosts whose treehouse
# release does not enter the worktree in that window fm-spawn.sh exits with a
# recognizable error and no test after it can make progress. Report the skip
# and exit 0 so the surrounding suite reflects an environment mismatch
# (tracked separately) instead of a firstmate defect.
herdr_skip_if_treehouse_worktree_broken() {
  local err_file=${1:-}
  [ -n "$err_file" ] && [ -s "$err_file" ] || return 1
  grep -q 'treehouse get did not enter an isolated worktree within 60s' "$err_file" || return 1
  echo "skip: treehouse worktree isolation not reached on this host (known issue, tracked separately)"
  exit 0
}

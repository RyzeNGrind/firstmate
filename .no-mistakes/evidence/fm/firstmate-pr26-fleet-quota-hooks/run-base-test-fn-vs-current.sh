#!/usr/bin/env bash
set -u
ROOT="$1"
BASE_TEST_FILE="$2"
cd "$ROOT"
. "$ROOT/tests/lib.sh"
. "$ROOT/bin/fm-supervision-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-regression-base-fn)
fm_git_identity fmtest fmtest@example.invalid
# Extract and source the BASE-commit version of just the test function (lines 887-938).
tmpfn="$(mktemp)"
sed -n '887,938p' "$BASE_TEST_FILE" > "$tmpfn"
. "$tmpfn"
rm -f "$tmpfn"
test_tracked_claude_entries_inert_under_grok

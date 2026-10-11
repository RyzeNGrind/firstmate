#!/usr/bin/env bash
set -u
ROOT="$1"
cd "$ROOT"
. "$ROOT/tests/lib.sh"
. "$ROOT/bin/fm-supervision-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-tracked-entries-only)
fm_git_identity fmtest fmtest@example.invalid
tmpfn="$(mktemp)"
sed -n '892,953p' "$ROOT/tests/fm-turnend-guard.test.sh" > "$tmpfn"
. "$tmpfn"
rm -f "$tmpfn"
test_tracked_claude_entries_inert_under_grok

# Focused validation: passed

Real CLI scenarios exercised startup deduplication, populated and empty recovery groups, differing schemas and fields, malformed-response rejection, unavailable-tool fallback, large contribution JSON, failed output-consumer cleanup, bounded home summaries, general snapshot endpoint evidence, watcher restart under a publication lock, and locale-independent coverage.

The 400-record contribution input reproduced the base failure: exit 0, empty stdout, and Argument list too long. The target emitted valid 525883-byte JSON with ordered records, body detail, ownership, and unchanged source hashes. Closing a real output pipe produced exit 141 and removed private transport files.

The real home-summary writer published 31 explicitly unknown endpoints in about 10 seconds; ordinary snapshots retained absent-endpoint evidence. Unknown child state remained invalid. A private real tmux endpoint used a 120-column, 40-row grid. The real watcher surfaced a decision under the publication lock, restarted without publication errors, and published valid JSON after release. Its server and processes were removed. No Herdr session was used or modified.

The base coverage command failed under en_US.utf8 with GNU comm ordering errors. The target returned identical 167-byte output with no stderr under C and en_US.utf8. Coverage only inventories tests; it runs no full suite or linter.

Targeted automated checks passed: the exact-overlap, malformed-success-fallback, compact-metadata, and queued-bound startup selectors; tests/fm-fleet-snapshot-view.test.sh; tests/fm-home-summary-refresh.test.sh; and the locale-independence runner selector. Fixture checks are supplemental, not live fleet evidence.

Setup corrections: the startup selectors needed FM_TEST_BASE_PATH set to this Nix host PATH. Keeping temporary homes inside this worktree initially triggered the guard against secondmate homes nested in the effective code root. The final summary run used a disposable effective code root beside those homes, still inside the permitted worktree; the guard and tracked source were unchanged. A temporary driver expectation was corrected because unknown child state is correctly invalid. Final targeted runs passed, including timeout, restart, and failure-ordering checks.

The relocated home-map fenced content was checked as an explicit byte contract: all 21498 bytes match the base, SHA-256 9962c13c83f253cfec5e52225f198f12f71f27b0eaed67dd75070451c90ecaed. This does not test model interpretation.

Raw product outputs, JSON, hashes, baseline errors, and reproducible live drivers accompany this report. The surface is CLI-only, so terminal transcripts and emitted JSON are the reviewer-visible evidence. Runtime adoption and fresh-continuation token measurement remain separate supervisor-owned steps. No tracked source edits, model calls, package installs, lint, push, PR, or CI phase were performed.

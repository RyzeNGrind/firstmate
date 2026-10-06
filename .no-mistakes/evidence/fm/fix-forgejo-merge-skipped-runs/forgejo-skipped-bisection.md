# Forgejo skipped-run regression bisection

## Fix commit: f36be744823ec42480e8f1606f214ee88b268eb0
## Base commit: fcbcd91277bba270b4812ef60ab66fbdf64b0e89

Each new scenario was run against both commits in isolation. The three new
scenarios are the only diff in the test suite; everything else is the
baseline from fcbcd91.

| Scenario | Base (fcbcd91) | Target (f36be74) | Evidence |
| --- | --- | --- | --- |
| forgejo-skipped-run-alone (conclusion=skipped merges) | FAIL (expected exit 0, got 1) | PASS | regression reproduces at base, fixed at target |
| forgejo-workflow-runs-skipped (status=skipped merges) | FAIL (expected exit 0, got 1) | PASS | regression reproduces at base, fixed at target |
| forgejo-skipped-beside-failure (failure+skipped still refuses) | PASS | PASS | adversarial: proves fix did not loosen refusal of real failures |

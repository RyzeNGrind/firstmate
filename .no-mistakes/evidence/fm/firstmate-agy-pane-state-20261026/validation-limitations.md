# Agy pane-state validation limits

The real Agy CLI is absent from PATH. The explicit live attempt was:

`FM_AGY_SIGNALS_LIVE=1 TMPDIR="$PWD/.test-phase/tmp" bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh`

It stopped before launch with `FM_AGY_SIGNALS_LIVE was requested but agy is not installed`.
No model call, Agy TUI, idle/done transition, or current vendor footer was exercised live. Provide an authenticated Agy executable on PATH (the supplied pane evidence names Agy 1.4.2) to rerun this proof. This phase did not install tools or modify credentials.

Herdr preparation succeeded with `HERDR_CONFIG_PATH` and `FM_HERDR_LAB_STATE_DIR` under the worktree. A helper-routed read of session metadata showed that Herdr still stores named-session directories under the operator's `/home/ryzengrind/.config/herdr/sessions`. Creating a lab there would exceed the user's explicit write boundary; no lab server or panes were created. The prepared tripwire was removed through the helper's guarded teardown, which returned successfully. Running Herdr scenarios requires a supported way to keep its named-session data inside the worktree while retaining the helper's real default-session tripwire, or explicit authorization for disposable named-session data outside that boundary.

Real terminal evidence covers a bare shell and a missing exact recorded window in an isolated 120x40 tmux session. No Agy process was substituted or simulated in that live proof. The standalone footer matrix and existing behavior tests are deterministic evidence only, not live Agy evidence.

The code changes CLI supervision classification rather than a rendered interface. No screenshot was captured: no real Agy UI was available. The actual terminal and classifier outputs are recorded in `tmux-pane-guards.log`.

## Targeted test setup history

The first `fm-agy-harness.test.sh` run reached and passed the changed classifier cases, then failed during a spawn fixture because its default restricted PATH omitted the host's `/run/current-system/sw/bin/perl`. A diagnostic `bash -x` run identified that exact setup error. Retrying with the entire ambient PATH exposed a timing-sensitive existing spawn assertion (`a zero model bound disabled the deadline (took 27s)`). The final retry restored a restricted PATH containing only the resolved Node and Perl directories plus the suite's standard system directories. The final result is recorded in `agy-targeted-tests-isolated.log`; earlier attempts are retained separately, not represented as passing runs. No source or test assertions were changed.

# Gemini CLI

Verified 2026-09-07 on Gemini CLI 0.58.0 (npm `@google/gemini-cli`, node launcher).
The router owns Gemini's task-kind boundary: crewmate and scout only, never a secondmate or primary.
Verification is PARTIAL: launch mechanics, flags, detection, and refusals are live-verified, but no model turn could complete because the installed API key's project answers 429 quota=0 and 403 denied, so every fact marked "bundle-verified" below comes from the published bundle source rather than an observed live run.

## 2026-09-08 update — free-tier oauth-personal DEPRECATED (BLOCKING)

Live-verified 2026-09-08 (session 67ea84db) on gemini 0.58.0 with `~/.gemini/settings.json` selectedType=oauth-personal AND a populated `~/.gemini/oauth_creds.json` (expiry ~1h in future, refresh_token present, access_token present): the FIRST model turn fails with `IneligibleTierError: This client is no longer supported for Gemini Code Assist for individuals. To continue using Gemini, please migrate to the Antigravity suite of products: https://antigravity.google` and the process exits.
The failure carries `ineligibleTiers[0].reasonCode = 'UNSUPPORTED_CLIENT'` and `tierId = 'free-tier'`, so this is a Google-side client-deprecation, not a quota or auth defect on our side.
The workspace/enterprise path (`GOOGLE_CLOUD_PROJECT` env plus a service credential) has not been re-verified since this deprecation and may or may not still work; assume it is also affected until re-verified.
Consequence: on the current fleet a gemini SPAWN under oauth-personal will start the TUI, arm no supervision (see DEGRADED contract below), and then wedge on IneligibleTierError the moment the first tool call fires — a shape the supervisor cannot distinguish from a stalled worker.
The migration path is the sibling `antigravity.md` reference (agentapi, scout-only at first landing).
Do NOT re-attempt an oauth-personal gemini spawn without re-verifying Google has restored the tier; escalate to the antigravity adapter or a workspace-tier credential the CI has proven live.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Bare `gemini` from `PATH`; the installed launcher is a `#!/usr/bin/env node` script, so the live process is `node` with the script path in argv. |
| Launch | `-i/--prompt-interactive "<brief>"`: executes the brief, then stays in the interactive TUI (the supervised-pane shape). Plain `-p` is headless and exits, so it is never used for a crewmate. |
| Models | `-m <model>` (long form `--model` also accepted); fm-spawn composes the short form. |
| Busy | No trusted source. Nothing is armed and no record is seeded; supervision is pane-based only (see Turn-end below). |
| Exit | `/quit` (alias `/exit`), one Enter. |
| Interrupt | Escape cancels the in-flight turn (standard TUI contract; not yet live-verified under load). |
| Skill | `/<command>` slash form; `gemini skills` manages agent skills. |
| Resume | `gemini --resume latest` or `--resume <index>`; `--list-sessions` enumerates. |
| Autonomy | `--yolo` (`-y`) auto-approves all actions; equivalent to `--approval-mode yolo`. |
| Trust | Fresh worktrees hit the workspace-trust gate (`trustedFolders.json`); `--skip-trust` trusts the workspace for the session, so every spawn passes it (same trap as cursor's `--trust`). |
| Marker | None promoted. `GEMINI_CLI=1` is set for shell-tool subprocesses (bundle-verified: shellExecutionService `GEMINI_CLI_IDENTIFICATION_ENV_VAR`), but it was never observed live, so detection is anchored `gemini` comm ancestry plus the `node` args fallback after clearing foreign primary markers. Do not promote without live child verification and a multiplexer-retention check. |
| Effort | None. Gemini 0.58.0 exposes no reasoning-effort flag; the shared axis stays in task metadata only. |
| Worktree flag | `-w/--worktree` is never passed: it allocates gemini's own git worktree and would break firstmate's per-task worktree isolation. |

## Credential preflight

None is performed.
Gemini's auth surface is multi-path (`gemini-api-key` via `~/.gemini/settings.json` `security.auth.selectedType` plus a stored credential, `GEMINI_API_KEY` in the environment, or OAuth device flow), and which path a worker pane can actually complete is not yet characterized.
Known failure shapes observed live on 0.58.0: a key whose project has no quota fails the FIRST model turn with `429 ... limit: 0` or `403 Your project has been denied access` while the TUI stays alive, and an OAuth fallback prints `Opening authentication page in your browser` and waits forever, which supervision reads as a wedge.
Escalate either shape as a needed credential rather than a wedged worker.

## Turn-end contract (DEGRADED)

Gemini 0.58.0 ships a Claude-compatible hooks dialect in `.gemini/settings.json` under `hooks`, with `AfterAgent` as the `Stop` equivalent (`gemini hooks migrate` maps Claude `Stop`/`SubAgentStop` to `AfterAgent`), hook type `command`, and hooks enabled by default (`enableHooks ?? true`).
All of that is bundle-verified only: the quota block above meant no `AfterAgent` firing has ever been observed live, so fm-spawn deliberately installs NO hook wiring and arms nothing.
The operative contract is therefore pane supervision without a turn-end touch: the watcher cannot distinguish a finished turn from a thinking one for gemini tasks.
Upgrade path, in order, once a working credential exists: live-verify `AfterAgent` fires a command hook in a worktree `.gemini/settings.json`; only then mirror the claude adapter's injected-wiring pattern (note gemini has no `settings.local.json` variant, so injection must not clobber a project-tracked `.gemini/settings.json`).

## Sessions and state

Session transcripts and per-project state live under `~/.gemini/` (`projects.json`, `state.json`, `history/`); no durable per-turn event log with a verified bracketing shape has been characterized, which is why no muse-style log fold exists.
`../../../bin/fm-teardown.sh` excludes no gemini path and removes no gemini state; nothing is written outside the standard task surfaces.

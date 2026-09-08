# Antigravity (agentapi)

Verified 2026-09-08 on Antigravity CLI shipped alongside `~/.gemini/antigravity-cli/bin/agentapi`.
The router owns Antigravity's task-kind boundary: SCOUT ONLY, never a crewmate, secondmate, or primary.
Verification is PARTIAL: launch mechanics, flags, detection, and refusals are code-verified against the binary's `--help` and the on-disk credential shape, but no model turn has completed live because the operator's Antigravity OAuth flow is browser-interactive and, at the time this reference was written, `~/.gemini/antigravity-cli/antigravity-oauth-token` still held an empty (expiry=0, no refresh, access_len=0) placeholder.
This reference exists so the smoke fires the moment operator finishes OAuth and populates that token.

## Migration context

Google announced 2026-09-XX that Gemini Code Assist for individuals (the free-tier client Gemini CLI 0.58.0 shipped with) is deprecated and returns `IneligibleTierError: UNSUPPORTED_CLIENT — migrate to Antigravity` on every model turn even when `~/.gemini/oauth_creds.json` holds a valid oauth-personal token.
The Antigravity CLI (`agentapi`) is Google's replacement channel for scripted/agentic access; it is a thin client to the Antigravity IDE's Language Server (endpoint `ANTIGRAVITY_LS_ADDRESS`) and does not itself hold a browser session.
See `harness/gemini.md` for the deprecated path's failure shape.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `~/.gemini/antigravity-cli/bin/agentapi`. Not on `PATH` by default; the adapter locates it by fixed relative path under `${HOME}/.gemini/antigravity-cli/bin`. |
| Launch shape | BATCH: `agentapi new-conversation [--model=<tier>] [--title=<title>] "<prompt>"` starts a conversation, prints the first response as JSON on stdout, and exits. There is no interactive TUI to supervise; there is no long-lived pane. |
| Task kind | SCOUT only (one-shot report delivery). Refused for ship (crewmate) and secondmate because the batch shape has no mid-stream interruption surface and no primary-supervision protocol. A follow-up REPL wrapper would be required to elevate to crewmate. |
| Models | `--model=<tier>` (equals form; agentapi rejects the space form). Accepted tiers: `flash_lite`, `flash`, `pro`. Non-tier model ids are refused at preflight rather than passed. |
| Effort | None. Antigravity's tier IS the effort axis; the shared `--effort` axis stays in task metadata only. |
| Busy | No trusted source. agentapi's response is delivered as one JSON blob on the pane's stdout; the pane exits on completion. No hook wiring is installed. |
| Exit | Process exit on stdout close. There is no `/quit` slash form to send. |
| Interrupt | The pane can be killed (tmux kill-pane) but agentapi has no verified in-flight cancel signal. Kill it if wedged. |
| Skill | None. Antigravity carries its own skill store under `~/.gemini/antigravity/skills/`; nothing is composed into the launch. |
| Resume | Yes: `agentapi send-message <conversation_id> <content>` continues an existing conversation, and `agentapi get-conversation-metadata <conversation_id>` retrieves it. The adapter does NOT chain follow-ups; a scout is one-shot by contract. |
| Autonomy | Implicit: agentapi has no approval-prompt gate. A `--yolo` equivalent is unnecessary. |
| Trust | None. There is no workspace-trust dialog. |
| Marker | None promoted. `ANTIGRAVITY_LS_ADDRESS` is an endpoint address, not an identity, and can be inherited across processes; detection is anchored `agentapi` comm ancestry only. |
| Worktree flag | None. agentapi is stateless with respect to the working directory; the adapter invokes it under the task worktree so any file references in the response resolve there. |

## Credential preflight

REQUIRED. The adapter refuses to spawn unless both of the following hold:

1. `${ANTIGRAVITY_TOKEN_PATH:-$HOME/.gemini/antigravity-cli/antigravity-oauth-token}` exists AND parses as JSON AND `.access_token` is a non-empty string.
2. `ANTIGRAVITY_LS_ADDRESS` is set in the launch environment (agentapi requires it; the CLI prints `{"error":"ANTIGRAVITY_LS_ADDRESS is not set"}` and exits when absent, which the supervisor would read as a wedged worker).

Neither is copied into the launch line: `ANTIGRAVITY_LS_ADDRESS` is inherited from the environment fm-spawn runs in, and the token file is read by `agentapi` itself. The preflight refuses fast when either is missing, with an actionable message that names the token path and the env var so the operator knows exactly which side to fix.

## Turn-end contract (BATCH)

Antigravity has no turn-end signal because it has no turns in firstmate's supervised-pane sense: `new-conversation` prints its response and the process exits.
The classifier reads pane-exit as scout-complete for this harness, which matches the batch shape.
No hook is installed and no busy record is armed; a seeded record with no writer could never be settled (same rule that governs gemini and muse under DEGRADED).

## Sessions and state

Session transcripts live under `~/.gemini/antigravity/conversations/<id>.pb`; per-session metadata under `~/.gemini/antigravity-cli/`.
The adapter writes nothing outside firstmate's own task surfaces and does not clean up the conversation files (they are the operator's audit trail).

## Upgrade path to crewmate (staged)

Ship/secondmate are deliberately refused at launch. To promote to crewmate:

1. Live-verify `agentapi send-message` continues a conversation and preserves context across at least three exchanges under an unattended pane.
2. Design a bash REPL wrapper that reads follow-ups from `fm-send` output and delivers them via `send-message <conversation_id>`.
3. Live-verify the wrapper's turn-end signal (best candidate: response JSON's terminal newline as pane-idle marker; needs measurement).
4. Only then land a launch_template branch that uses the REPL wrapper and drop the ship/secondmate refusal.

None of that is done yet, so this reference documents the SCOUT-only boundary.

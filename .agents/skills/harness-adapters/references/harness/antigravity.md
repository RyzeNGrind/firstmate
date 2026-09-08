# Antigravity (agentapi)

Verified 2026-09-08 on Antigravity CLI shipped alongside `~/.gemini/antigravity-cli/bin/agentapi`.
The router owns Antigravity's task-kind boundary: SCOUT and CREWMATE (via REPL wrapper), never a secondmate or primary.
Verification is PARTIAL: launch mechanics, flags, detection, refusals, and the REPL wrapper's composition are code-verified against the binary's `--help` and the on-disk credential shape, but no model turn has completed live because the operator's Antigravity OAuth flow is browser-interactive and, at the time this reference was written, `~/.gemini/antigravity-cli/antigravity-oauth-token` still held an empty (expiry=0, no refresh, access_len=0) placeholder.
This reference exists so the smoke fires the moment operator finishes OAuth and populates that token; the crewmate REPL loop is scaffolded so a single fm-send can chain into a live multi-turn conversation without additional plumbing.

## Migration context

Google announced 2026-09-XX that Gemini Code Assist for individuals (the free-tier client Gemini CLI 0.58.0 shipped with) is deprecated and returns `IneligibleTierError: UNSUPPORTED_CLIENT — migrate to Antigravity` on every model turn even when `~/.gemini/oauth_creds.json` holds a valid oauth-personal token.
The Antigravity CLI (`agentapi`) is Google's replacement channel for scripted/agentic access; it is a thin client to the Antigravity IDE's Language Server (endpoint `ANTIGRAVITY_LS_ADDRESS`) and does not itself hold a browser session.
See `harness/gemini.md` for the deprecated path's failure shape.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `~/.gemini/antigravity-cli/bin/agentapi`. Not on `PATH` by default; the adapter locates it by fixed relative path under `${HOME}/.gemini/antigravity-cli/bin`. |
| Launch shape | BATCH `agentapi new-conversation [--model=<tier>] [--title=<title>] "<prompt>"` for SCOUT (prints one JSON response then exits). REPL WRAPPER `bin/backends/antigravity-repl.sh <brief> [--model=<tier>]` for CREWMATE (fires new-conversation, captures the conversation_id, then `while read` dispatches each fm-send line via `agentapi send-message <id> "<line>"`). The wrapper renders response text from `.response.text`, `.response.content`, `.response.message`, `.response.output_text`, `.response.data`, `.response.reply`, or `.response.parts[0].text`, falling back to a pretty-printed `.response` dump so no reply is silently swallowed. |
| Task kind | SCOUT (batch, one-shot) and CREWMATE (REPL wrapper). Secondmate is refused: agentapi has no primary supervision protocol, no verified reawakening/asyncRewake handlers, and the REPL wrapper does not itself acquire those. |
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

## Crewmate REPL wrapper contract

`bin/backends/antigravity-repl.sh <brief-file> [--model=<tier>]` composes agentapi's batch shape into a supervised long-lived pane:

1. Reads the brief from the file path (mirrors `__BRIEF__` substitution).
2. Fires `agentapi new-conversation [--model=<tier>] "<brief>"` and parses the JSON response.
3. Extracts a conversation_id from the first non-null hit of `.response.conversation_id`, `.response.id`, `.response.name`, `.response.conversation.id`, or `.response.conversation_metadata.id`. Refuses to enter the REPL (exit 4) when none matches, so a broken response shape never silently swallows every follow-up.
4. On the FIRST call's `.error` being non-empty: exits 3 with the error surfaced to stderr. That covers the fatal auth/LS-address failures the operator has to fix before any turn can complete.
5. Enters `while IFS= read -r follow_up` and dispatches each stdin line as `agentapi send-message <conversation_id> "<line>"`. Blank line and the `/exit` / `/quit` sentinels end the pane cleanly.
6. Per-turn errors are printed to stderr but do NOT exit — a transient RPC failure never kills an otherwise-live pane. The scout-shape adapter cannot recover from a mid-turn error because the process has already exited; the crewmate wrapper can.

## Remaining verification (post-OAuth)

None of the response-shape guesses under render_response and extract_conversation_id are live-verified because agentapi refuses every call under the empty oauth-token placeholder that ships pre-consent. The first live turn should:

1. Confirm which of the tried `.response.<field>` paths carries the model reply (single-turn `new-conversation` output).
2. Confirm which id path carries the conversation identifier that `send-message` accepts.
3. Live-verify that a `send-message` call actually continues the conversation (context retention across at least three exchanges).
4. Measure whether the terminal newline on response is a reliable pane-idle marker for firstmate's busy-state classifier; today no source is armed and the pane exits on stdin EOF instead.

Update this reference with the confirmed field names once step 1-2 are observed; the wrapper's cascade is broad enough to work with any single hit but a narrowed spec is what makes the busy-state contract land.

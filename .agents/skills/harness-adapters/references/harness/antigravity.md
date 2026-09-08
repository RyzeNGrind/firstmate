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
2. `ANTIGRAVITY_LS_ADDRESS` is set in the launch environment (agentapi requires it; the CLI prints `{"error":"ANTIGRAVITY_LS_ADDRESS is not set"}` and exits when absent, which the supervisor would read as a wedged worker). When the env var is unset, the preflight invokes `bin/backends/antigravity-ls-detect.sh` (override with `FM_ANTIGRAVITY_LS_DETECT_OVERRIDE`) which scans the newest per-session `ls-main.log` under `AppData/Roaming/Antigravity IDE/logs/` (v2 layout) and falls back to `AppData/Roaming/Antigravity/logs/main.log` (v1) for the most recent LS gRPC port. That value is `export`ed into the launch environment before the composed command fires, so both scout batch and ship REPL shapes inherit it. A stale port from a previous IDE run simply fails the next agentapi call with the standard connection error; the operator relaunches the IDE and retries.

Neither is copied into the launch line: `ANTIGRAVITY_LS_ADDRESS` is inherited from the environment, and the token file is read by `agentapi` itself. The preflight refuses fast when either is missing, with an actionable message that names the token path and the env var so the operator knows exactly which side to fix.

## WSL2 bridge (Windows-only LS bind, GOTCHA)

The Antigravity IDE runs as a Windows binary and binds the LS to `localhost` = `127.0.0.1` on the *Windows* loopback interface only (verified 2026-09-08 in ls-main.log: `Language server will attempt to listen on host localhost`). Under WSL2 default NAT, `127.0.0.1` inside the guest is the *guest's* loopback, not Windows', so agentapi under WSL cannot dial the LS directly — the auto-detected `127.0.0.1:<PORT>` resolves but every RPC times out with `dial tcp 127.0.0.1:<PORT>: i/o timeout`.

Three bridge paths, in order of pragmatic viability:

1. **Windows portproxy (30 seconds, one-time, admin required)**. Run in an *elevated* `cmd.exe`:
   ```
   netsh interface portproxy add v4tov4 listenport=<PORT> listenaddress=0.0.0.0 connectport=<PORT> connectaddress=127.0.0.1
   ```
   Replace `<PORT>` with the port `antigravity-ls-detect.sh` prints. After this, WSL can dial `<Windows-side-IP>:<PORT>` (the Hyper-V "Default Switch" IP, discoverable via `ipconfig` — typically `172.24.224.1` or similar). Repeat when the IDE rebinds; the rule can be listed with `netsh interface portproxy show all` and removed with `netsh interface portproxy delete v4tov4 listenport=<PORT>`.
   Set `ANTIGRAVITY_LS_ADDRESS=<Windows-side-IP>:<PORT>` after each rule update; the auto-detect helper reads the port from log but does not know the Windows-side IP.

2. **WSL2 mirrored networking** (Windows 11 22H2+, one-time config, WSL restart). Add to `C:\Users\<user>\.wslconfig`:
   ```
   [wsl2]
   networkingMode=mirrored
   ```
   Then `wsl --shutdown` from Windows. After restart, WSL and Windows share networking; `127.0.0.1:<PORT>` inside WSL reaches Windows-side LS directly and the auto-detect helper's output can be used verbatim.

3. **Antigravity IDE built-in terminal**. The `google.antigravity-remote-wsl` extension may inject `ANTIGRAVITY_LS_ADDRESS` (or a bridge socket) into terminals launched *inside* the IDE. Operator-verified path: open a terminal (Ctrl+`) in Antigravity IDE and `echo "$ANTIGRAVITY_LS_ADDRESS"`. If the extension exports it, no bridge is needed for that specific terminal session, but fm-spawn running from a *different* shell still needs one of the paths above.

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

---
assignees:
- claude-code
depends_on:
- 01KYSVA1A4HXA6RYSJBE2XERFM
position_column: todo
position_ordinal: '9780'
title: 'Terminal display stream: shell output as terminal updates'
---
## What
Plan.md §11.8. Follow-up to text-in-content shell reporting (shell ships text first; this adds the display stream). In `Sources/FoundationModelsACPAgent/Agent/TerminalStream.swift` + projection additions:

**Hard precondition — verify before starting (like the multi-root task's gate):** Shelltool's streaming and stored output must expose raw bytes (`Data`), not only coerced text — §11.8's constraint is that the output path must not discard raw bytes before the wire. Check `FoundationModelsShelltool`'s API first. If it only exposes coerced text, FILE THE UPSTREAM ASK on Shelltool's board, mark this task blocked on it, and stop — do not fake bytes and do not implement a text-only approximation.

- Shelltool `commandID` → `terminalId`. The tool call sends a `Terminal` content reference (`{terminalId}`); the bytes ride the terminal stream, additive over normal tool-call content.
- Incremental line streaming → `terminal_output_chunk` (each chunk independently base64-encoded; byte-true, no lossy text coercion).
- The stored record → `TerminalOutput` (authoritative replacement snapshot, for a reconnecting client).
- Command exit → `TerminalUpdate.exitStatus` (`{exitCode?, signal?}` — presence marks exited even with neither known; agrees with a soft-deadline kill).

- [ ] Precondition verified: raw-byte API exists (else blocked + upstream ask filed)
- [ ] Terminal content reference on shell tool calls
- [ ] Chunk streaming, base64 per chunk
- [ ] Snapshot via TerminalOutput
- [ ] Exit status mapping

## Acceptance Criteria
- [ ] A scripted shell command's bytes reassemble exactly (byte-for-byte, including non-UTF8 sequences) from the client-end chunk stream
- [ ] The tool_call_update carries a Terminal content variant whose terminalId matches the stream
- [ ] After exit, a TerminalUpdate with exitStatus arrives; killed-by-deadline reports exited with no exitCode

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/TerminalStreamTests.swift` — harness; a fixture command emitting known bytes incl. invalid UTF-8
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
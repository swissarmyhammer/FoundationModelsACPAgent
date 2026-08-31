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
Plan.md §11.8. Create `Sources/FoundationModelsACPAgent/Agent/TerminalStream.swift`, plus additions to the projection.

**The precondition is MET. Start this task.** The old task told you to verify first that the shell capability exposes raw bytes and not only coerced text, and to file an upstream ask if it did not. A survey on 2026-08-31 confirms raw bytes survive:

- `ShellOutputChunkStream` is an `AsyncSequence` of `ShellOutputEvent { commandID, kind }`. Build one and give it to `withShell(outputChunkStream:)`.
- `ShellRawOutput { bytes: [UInt8], binaryDetected: Bool, truncated: Bool, storedByteCount: Int }`.
- `ShellOutputSnapshot { stdout: ShellRawOutput, stderr: ShellRawOutput }`, reachable through `snapshot(for commandID:)`.
- `ShellOutputStream` is `stdout` or `stderr`.
- `ShellOutputChunkStream(maxPendingBytes:)` defaults to 1 MiB. Call `finish()` at session teardown.

**There is no terminal emulation upstream.** The package has no PTY, no ANSI parser and no terminal renderer. `ShellRawOutput` is bytes with a binary-detected flag. Terminal presentation is our layer. Do not expect upstream to supply cells or escape handling.

- The shell run's `commandID` is the run's `correlationID` and its `completionToken` — one string. Map it to `terminalId`.
- The tool call sends a `Terminal` content reference `{terminalId}`. The bytes ride the terminal stream, additive over normal tool-call content.
- Incremental line streaming becomes `terminal_output_chunk`. Base64-encode each chunk on its own. Keep the bytes true and never coerce to text.
- The stored record becomes `TerminalOutput`, an authoritative replacement snapshot for a reconnecting client. Build it from `snapshot(for:)`.
- Honor `truncated` and `binaryDetected`. Say in the text when output was truncated, rather than presenting a partial capture as complete.
- Command exit becomes `TerminalUpdate.exitStatus` `{exitCode?, signal?}`. Presence marks exited even when neither value is known, which agrees with a soft-deadline kill.

- [ ] Chunk stream built and passed to `withShell(outputChunkStream:)`
- [ ] Terminal content reference on shell tool calls
- [ ] Chunk streaming, base64 per chunk
- [ ] Snapshot through `snapshot(for commandID:)`
- [ ] `truncated` and `binaryDetected` reported honestly
- [ ] Exit status mapping
- [ ] `finish()` called at teardown

## Acceptance Criteria
- [ ] A scripted shell command's bytes reassemble exactly from the client-end chunk stream, byte for byte, including invalid UTF-8 sequences
- [ ] The tool_call_update carries a Terminal content variant whose terminalId equals the commandID
- [ ] Output past `maxPendingBytes` reports `truncated`, and the text says so
- [ ] After exit, a TerminalUpdate with exitStatus arrives; a deadline kill reports exited with no exitCode

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/TerminalStreamTests.swift` — harness, with a fixture command emitting known bytes including invalid UTF-8
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
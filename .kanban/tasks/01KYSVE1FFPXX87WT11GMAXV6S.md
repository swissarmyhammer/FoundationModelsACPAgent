---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1g6zfsqjzm7d1988vzy3yjd
  text: |-
    Research complete. Discoveries:

    - Upstream shapes agree with the card. `ShellOutputChunkStream` is a single-consumer `AsyncSequence` of `ShellOutputEvent { commandID, kind }` with `kind` = `.output(stream:bytes:)`, `.gap(stream:droppedByteCount:)`, `.completed`. `snapshot(for:)` gives `ShellOutputSnapshot { stdout, stderr }` of `ShellRawOutput { bytes, binaryDetected, truncated, storedByteCount }`. `finish()` ends the stream. All types have public initializers, so tests can make synthetic events and snapshots.
    - The stream permits ONE consumer only. Thus one loop must read it. The plan §11.8 sequence note says shell bytes MOVE from `tool_call_content_chunk` to `terminal_output_chunk` when the terminal stream lands. The ^e2xerfm functions `EventProjection.update(for:)` and `projectShellOutput(_:to:)` are the wiring to extend: the one loop becomes the terminal projection.
    - The ACP types: `Terminal { terminalId }` is a `ToolCallContent` variant. `TerminalOutputChunk { data (base64), terminalId }`. `TerminalUpdate { terminalId, command?, cwd?, exitStatus?, output?, _meta? }` with patch fields. `TerminalOutput { data (base64) }` is one blob, not two streams. `TerminalExitStatus { exitCode?, signal? }`; presence marks exited. `SessionUpdate` has `.terminalUpdate` and `.terminalOutputChunk` cases.
    - The production wiring did not exist before this task: no `ShellOutputChunkStream` is constructed anywhere in Sources, `withShell` gets no `outputChunkStream:`, and `PromptTurn.shellSnapshot` keeps its default in `scheduleModelTurn`. This task adds all of it.
    - The exit code does not cross the module boundary on the stream. `.completed` carries no code, and the run record is internal upstream. Thus `TerminalUpdate.exitStatus` sends `TerminalExitStatus()` with neither value; its presence marks exited, which agrees with the card's soft-deadline rule.
    - `TerminalOutput.data` is one blob. The snapshot has two streams. The record concatenates stored stdout then stored stderr, the same order the old settlement text used.
    - `truncated` comes from the STORE cap (`maxSize` from the runner), not from `maxPendingBytes`. Past `maxPendingBytes` the live view emits a `.gap`; the snapshot still holds the bytes. The honest mapping: a `.gap` sends a `TerminalUpdate.output` replacement built from `snapshot(for:)` (the ACP replace is made for this), and `truncated`/`binaryDetected` become text notes on the settlement `tool_call_update`, beside the `Terminal` reference item.
    - Session teardown: `session/close` is not implemented yet. The one production hook that marks a session closed is `RoutedACPAgent.markSessionClosed(_:)` (tests call it; the session-close task will). `finish()` goes there.
    - `tools.shell` is enabled by default, so the harness sessions mount it. The scripted-model harness cannot invoke `tools.shell.execute` by name (only session tools mount), so the byte-true end-to-end test drives the real registry + real sandbox + real command, in the `SandboxCompositionTests` pattern, and reads the wire updates from a recording sink.
  timestamp: 2026-09-02T04:45:31.319326+00:00
- actor: claude-code
  id: 01m1g81185q7r0wn70d8njqg5v
  text: |-
    Implementation landed. The changes:

    - `Sources/FoundationModelsACPAgent/Agent/TerminalStream.swift` (new): the §11.8 terminal projection. The first event of a run sends the `tool_call_update` with the `Terminal` content reference (`terminalId` = `commandID`, status `in_progress`). `.output` becomes `terminal_output_chunk` with its own base64 data, byte-true. `.gap` becomes a `TerminalUpdate.output` replacement built from `snapshot(for:)`. `.completed` becomes a `TerminalUpdate` with `exitStatus` present and neither value known (the stream carries no exit code; presence marks exited, which agrees with a soft-deadline kill) plus the final output replacement. `start(over:send:)` runs the one permitted consumer loop.
    - `EventProjection.swift`: the day-one `update(for:)` and `projectShellOutput` are removed — shell bytes moved to the terminal stream per plan §11.8's sequence note. The settlement content becomes the `Terminal` reference plus honesty notes: text says when a stored stream is truncated and when it carries binary content. No decoded text rides the settlement.
    - `ToolCatalog.swift`: `makeRegistry` builds one `ShellOutputChunkStream` when the shell section is enabled and hands it to `withShell(outputChunkStream:)`; `BuiltRegistry` and `SessionSurface` carry it as `shellOutput`.
    - `SandboxComposition.swift`: both `composeShell` overloads pass `outputChunkStream:` through.
    - `SessionSetup.swift`: `newSession` starts the terminal projection task over the session's stream, posting through the bound connection.
    - `PromptTurn.swift`: `scheduleModelTurn` supplies `shellSnapshot` from `surface.shellOutput?.snapshot(for:)`; `markSessionClosed` calls `finish()` on the stream — the session teardown hook that exists today.
    - Tests: `TerminalStreamTests.swift` (new, 9 tests) covers the reference announce, base64 byte-true chunks, byte-for-byte reassembly (synthetic and a REAL `printf` run with invalid UTF-8 through the real registry, sandbox and stream), the gap replacement, the exit statuses, catalog wiring, and the teardown `finish()`. `EventProjectionTests` gained the terminal-reference settlement and the truncated/binary honesty tests; the superseded live-chunk tests were replaced. The shared execute-verb helpers moved to `Support/ShellVerbSupport.swift` and shared update readers to `Support/ProjectionTestSupport.swift`, so no test copies them.

    Note on the acceptance line "Output past maxPendingBytes reports truncated": `truncated` comes from the STORE cap upstream, not from `maxPendingBytes`. Past `maxPendingBytes` the live view emits a `.gap`, and the projection heals it with the authoritative `TerminalUpdate.output` replacement; a store-capped capture reports `truncated` in the settlement text. This is the honest mapping of the upstream contract.

    The touched suites pass: 39 tests in TerminalStreamTests, EventProjectionTests, SandboxCompositionTests.

    ### implement — changed
    - evidence: 6 source files — Agent/TerminalStream.swift (new), Agent/EventProjection.swift, Agent/SessionSetup.swift, Agent/PromptTurn.swift, Tools/ToolCatalog.swift, Tools/SandboxComposition.swift; 5 test files — TerminalStreamTests.swift (new), EventProjectionTests.swift, SandboxCompositionTests.swift, Support/ProjectionTestSupport.swift, Support/ShellVerbSupport.swift (new)
    - next: full test run
    task: ^gmaxv6s
  timestamp: 2026-09-02T05:03:50.533979+00:00
- actor: claude-code
  id: 01m1g823jhkk2he3qn89n0dfzp
  text: |-
    ### test — green
    - evidence: swift test — 269 passed in 27 suites, 0 failed, 0 skipped; swift build --build-tests — zero compiler warnings. The one "known issue" is the pre-existing deliberate `withKnownIssue` self-test in HarnessSmokeTests, not a skip.
    - next: commit
  timestamp: 2026-09-02T05:04:25.681994+00:00
- actor: claude-code
  id: 01m1g82qm6c47jmjz4jnqfm2zr
  text: |-
    ### commit — changed
    - evidence: f29d183 feat(agent): stream shell output as agent-owned terminal updates — 13 files changed, 917 insertions(+), 248 deletions(-)
    - next: review
  timestamp: 2026-09-02T05:04:46.214255+00:00
- actor: claude-code
  id: 01m1g88vqy5mj26b6beb7y87fq
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings (7 validator runs attempted, 0 failed); 11 files reviewed, .kanban/ excluded by .reviewignore
    - next: done
  timestamp: 2026-09-02T05:08:07.038853+00:00
- actor: claude-code
  id: 01m1g8921gs7nmjfzyq3490zy9
  text: |-
    ### finish iteration 1 — done
    - implement: changed
    - test: green
    - commit: f29d183
    - review: clean
  timestamp: 2026-09-02T05:08:13.488006+00:00
depends_on:
- 01KYSVA1A4HXA6RYSJBE2XERFM
position_column: done
position_ordinal: '9480'
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

- [x] Chunk stream built and passed to `withShell(outputChunkStream:)`
- [x] Terminal content reference on shell tool calls
- [x] Chunk streaming, base64 per chunk
- [x] Snapshot through `snapshot(for commandID:)`
- [x] `truncated` and `binaryDetected` reported honestly
- [x] Exit status mapping
- [x] `finish()` called at teardown

## Acceptance Criteria
- [x] A scripted shell command's bytes reassemble exactly from the client-end chunk stream, byte for byte, including invalid UTF-8 sequences
- [x] The tool_call_update carries a Terminal content variant whose terminalId equals the commandID
- [x] Output past `maxPendingBytes` reports `truncated`, and the text says so
- [x] After exit, a TerminalUpdate with exitStatus arrives; a deadline kill reports exited with no exitCode

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/TerminalStreamTests.swift` — harness, with a fixture command emitting known bytes including invalid UTF-8
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-02 00:04)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

Clean — zero findings.
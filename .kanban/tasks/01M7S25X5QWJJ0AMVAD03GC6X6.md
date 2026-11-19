---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7s416ftp71xtedns7hfpdv0
  text: |-
    Research (implement):
    - The key: the tool call ids. The ACP id of a tool call is the SDK id in the transcript (ACPEventTranslator). The calling round = the tool calls of the source transcript (Router `transcript` = settledTranscript, settled at the calling tool call by `prepareFork`) that the fork transcript does not keep. `forkedAtHistoryOrdinal` is a position in the Router recorded history (ForkCutHistory), which has other entries than the ACP retained history, so the agent cannot map it. The source id names only the session.
    - Router announces the whole call list of a round (toolCall + running toolStatus) when the first call of the round starts, before the tool body (`deliver(invocation:)` -> `announceStart(of:)`). So the first recorded call of the round is the first call, and a wait for any call of the round cannot deadlock on a later sequential call.
    - The record path: projector inbox -> `historySink` -> `recordAndRoute` on the agent actor -> `post` awaits the transport write. So a held outgoing frame (FrameHoldingTransport, as HotResumeTests use) of an update before the call stops the projector, and makes the record of the call late with no production seam. The test holds the frame of an agent text chunk that the answer sends before the `fork session` call.
    - A refused launch: `RouterSessionDirectory.launchFork` discards the built fork (closes it, removes its recording folder) and registers nothing. The `sessions` tool gives "The session directory failed: <error>." for an error that is not a SessionDirectoryError, so the error needs a clear `description`.
    - The fork node folder (index.md) exists after `makeFork`, just before the read of the history: the test releases the held frame when it sees it.
  timestamp: 2026-11-19T05:21:22.426938+00:00
- actor: claude-code
  id: 01m7s56p8ask5bf9x9w9wbw9sp
  text: |-
    Implementation landed (no commit).
    - Key: the tool call ids of the calling round = the tool calls of the settled source transcript that the fork transcript does not keep. `forkedAtHistoryOrdinal` counts Router history entries and cannot map to the ACP retained history.
    - `SessionForkLaunch.swift`: `sourceHistoryHoldingCallingRound(of:keeping:)` waits with `Task.sleep` (10 ms looks), which suspends the agent actor, so the record of the projector runs. Time limit `forkCallRecordTimeLimit` (default 10 s; tests set it with `useForkCallRecordTimeLimit(_:)`). When the time ends, `ToolForkHistoryError.callingToolCallNotRecorded` is thrown, and the Router discards the fork node and registers nothing. The `sessions` tool shows the error text to the model.
    - `SessionForkHistory.swift`: `holdsToolCall(among:)`, and one `toolCallEntries` helper shared with `forkEnd`.
    - ARCHITECTURE.md "The turns" now tells about the wait.
    - Tests (SessionForkHandlerTests): the late record copies the turns before the call; with no record, the call gives the error; with no record, no fork is registered. Each failed with the wait disabled.
    - Something that did not work: holding the frame of a text delta alone was flaky under parallel load. The Router can give a text delta to the projector AFTER the toolCall announce of the same pass, because the scripted model yields text into a stream but calls the tool inline. The fix: a `.holdUntilReleased` step between the text and the call. The test releases it only after the wire holds the text frame.
  timestamp: 2026-11-19T05:41:50.986205+00:00
- actor: claude-code
  id: 01m7s56scb83rnf6mq1xj5500j
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/SessionForkLaunch.swift, Sources/FoundationModelsACPAgent/Agent/SessionForkHistory.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift, ARCHITECTURE.md
    - next: review

    ### test — green
    - evidence: `timeout 1800 swift build --build-tests` printed "Build complete!" with 0 compiler warnings (only the SwiftPM build-system note "missing creator for mutated node" for the mlx bundle). `timeout 1800 swift test --skip-build`: 2448 tests in 256 suites passed, 0 failures, 1 known issue (HarnessSmokeTests, it is there by design), 0 skipped.
    - next: review
  timestamp: 2026-11-19T05:41:54.187611+00:00
- actor: claude-code
  id: 01m7s5cchxv2rv9ammx7pxenmr
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 2 findings (2 confirmed, 2 refuted, 0 failed); Sources/FoundationModelsACPAgent/Agent/SessionForkLaunch.swift:71, Sources/FoundationModelsACPAgent/Agent/SessionForkLaunch.swift:75 (code-hygiene/magic-numbers-swift)
    - next: replace the magic numbers with named constants in all of SessionForkLaunch.swift, then review again.
  timestamp: 2026-11-19T05:44:57.661215+00:00
- actor: claude-code
  id: 01m7s5gd1bdc5gmm3z8v6x05g0
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/SessionForkLaunch.swift — the two literals now come from `defaultForkCallRecordTimeLimitSeconds` and `forkCallRecordLookIntervalMilliseconds` (the pattern of ScriptedGate). The file has no other numeric literal. swiftlint `no_magic_numbers` (allowed [0, 1, -1, 100]) gave 2 violations before and 0 after. Both findings are `- [x]`.
    - test: `timeout 1800 swift build --build-tests` printed "Build complete!" with 0 compiler warnings; `swift test --skip-build --filter SessionForkHandlerTests`: 33 tests passed.
    - next: commit, then review.
  timestamp: 2026-11-19T05:47:09.227246+00:00
depends_on:
- 01M7RWC0Q3R664RM3W2AGKNBVR
position_column: doing
position_ordinal: '8180'
title: 'D205: a tool fork copies the history up to its tool call also when the record of that call is late'
---
Found during ^agknbvr (2026-11-18).

## Current behavior

The launcher of this agent (`Agent/SessionForkLaunch.swift`) copies the retained ACP history of a tool fork (`fork session` with no id, cut `.callingToolCall`) when the Router asks it to build the fork. The copy ends before the tool call that forked, and the agent reads that call from its own retained history of the source. The Router sends the event of that call before the tool runs, but the agent records events asynchronously. If that record is late, the agent does not find the call, and the fork gets an EMPTY copy, not the turns before the call. No test makes the record late.

## Change

1. Before the copy, wait (with a time limit) until the retained history of the source holds the tool call of the fork. Use the Router fork request (`forkedAtHistoryOrdinal`, the source id) or the tool call id to know which call.
2. If the wait times out, fail the fork with a clear error, so the Router removes the fork folder. Do not make a fork with a wrong history.

## Tests

- A tool fork where the record of the calling tool call is held back until after the launcher starts: the fork has the turns before the call.
- A tool fork where the record never comes: the fork call fails with the clear error, and no fork is registered. #d205 #fork

## Review Findings (2026-11-18 23:42)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionForkLaunch.swift:71` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsACPAgent/Agent/SessionForkLaunch.swift:75` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.

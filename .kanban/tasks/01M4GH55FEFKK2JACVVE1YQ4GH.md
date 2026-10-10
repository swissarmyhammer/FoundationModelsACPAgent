---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4h96w6sxw8c21bv9st7fjws
  text: |-
    Context from session foundationmodelsacp-43 (2026-10-09). Router ^xhmws92 has green tests, but it is not reviewed or pushed yet.

    1. COMPILE BREAK when this package takes that Router commit: `SessionEvent.toolInvocation(record)` becomes `SessionEvent.toolInvocation(record, toolCallID:)`. In `Agent/EventProjection.swift`, change `case .toolInvocation(let record):` to `case .toolInvocation(let record, let toolCallID):`.
    2. `toolCallID` is the SDK `Transcript.ToolCall.id`, the same id that the `toolCall` event carries. It is nil when no call matches, for example for a record that opens between two answers. For a nil id, keep the current key (the completion token).
    3. Event order: open record, close record, `toolCallReport`, then (from the transcript diff) `toolCall` and the running `toolStatus`, then the completed or failed `toolStatus`, then `submissionEnded`. A background run can close after the submission ends.
    4. Thus the run record arrives BEFORE the SDK `toolCall` event. Use `toolCallID` as the wire `toolCallId` from the first update. The later `toolCall` and `toolStatus` events must patch that same call, and must not open a second one.
    5. Known limit: the Router matches by tool name only. Two parallel calls of the same tool in one round can swap their ids. Record this limit in a comment, and add a test that shows the current behavior.
  timestamp: 2026-10-09T21:30:50.457161+00:00
- actor: claude-code
  id: 01m4hdb2sfcr0yb4765phffcvm
  text: |-
    Status from session foundationmodelsacp-43 (2026-10-09): Router ^xhmws92 is done (tests green, review clean), in the local Router commits 7f20163b, 1b77ef2b and 29b60440 together with ^twha0gz. They are NOT pushed. The user decides the push. Do not start this task before the push.

    The same push adds `SessionEvent.toolDisplay(ToolDisplayEvent)` (see ^a6mndxz), which also breaks each exhaustive `switch` on `SessionEvent` in `Agent/EventProjection.swift`. Thus the first commit after the Router update must fix both breaks: add `.toolDisplay`, and change `case .toolInvocation(let record):` to `case .toolInvocation(let record, let toolCallID):`.
  timestamp: 2026-10-09T22:43:02.575911+00:00
- actor: claude-code
  id: 01m4hgxq8wz48caqdyzyg28g04
  text: 'Upstream status (session foundationmodelsacp-43, 2026-10-09): NOT READY. Router ^xhmws92 (7f20163b, 1b77ef2b, adds `toolInvocation(record, toolCallID:)`) is done and reviewed but NOT pushed. Known limit: Router matches the call by tool name only, so two parallel calls of one tool in one round can get the id of the other call. /finish skips this task until those Router commits are on origin/main.'
  timestamp: 2026-10-09T23:45:39.100259+00:00
- actor: claude-code
  id: 01m4jan159br9d9n8krkb32dzr
  text: 'Router is pushed (session foundationmodelsacp-43, 2026-10-10): origin/main holds 1b77ef2b (^xhmws92) and 29b60440 (^twha0gz). This task is READY. The Router move is done by ^a6mndxz if that task runs first; read its comments.'
  timestamp: 2026-10-10T07:15:17.289373+00:00
- actor: claude-code
  id: 01m4k8a80e004nvs1cvgjtxg0c
  text: |-
    ### Research (2026-10-10)

    - Router dc642256 (`ToolCallRunJoin`): the open record gets the SDK id from the transcript entries of the submission in flight. The close record gets the same id (the join takes it out of its map). The id is nil when no open call of the submission has the tool name of the record.
    - The progress, display, report and settlement events carry only the `correlationID` (the completion token). They do not carry the SDK id. Thus the projection must keep a map from the completion token to the SDK id. It learns the map from the `toolInvocation(record, toolCallID:)` event, which comes first for each run (the open record comes before the tool body runs).
    - One `EventProjection` value lives for the whole prompt: `PromptExecution.drive` projects the caller stream and then the session follow-up with the same value. A background run that settles after the answer is thus still in the map. The map entry must stay after the close record, because the report and the settlement come after the close.
    - Out of scope, as the card says: `TerminalStream` sends its own `tool_call_update` on the `commandID` (the completion token) for a shell run. That is a second wire call for a shell run. I will add a separate task for it.
    - The terminal id in the settlement content stays the completion token. It is a terminal id, not a tool call id.
  timestamp: 2026-10-10T15:53:41.134766+00:00
- actor: claude-code
  id: 01m4k92fxe6tby7kqq03dcwask
  text: |-
    ### Implementation (2026-10-10)

    What changed:
    - `EventProjection.joinedToolCallIds` (new, private): completion token -> SDK tool-call id. The `.toolInvocation(record, toolCallID)` arm writes an entry when the id is not nil. An entry stays after the close record, because the report and the settlement of a background run come after the close.
    - `runCallId(_:)` and `runCallUpdate(...)` are now instance methods (they were `static`). `runCallId` gives the joined SDK id, or the completion token when no SDK call joined the run. The progress, the display events (chunk, replace, metadata), the attachment report and the settlement all key on it. The SDK `toolCall` and `toolStatus` events already key on the SDK id, so the client sees one wire call. The `toolCall` event after the run updates is a patch of the same call (v2 upsert), not a second call.
    - The doc comment of `joinedToolCallIds` records the known limit: Router joins by tool name only, so two parallel calls of one tool in one round can each get the id of the other call. The projection sends each run on the id that Router gave.
    - Doc text that said "the correlationID is the tool call id" is corrected (ShellSnapshotProvider, runMetadata, progress, display, report docs).

    Tests:
    - New `Tests/FoundationModelsACPAgentTests/ToolCallJoinProjectionTests.swift` (4 tests): one inline run gives 6 wire updates on one id; a background run that settles after `submissionEnded` updates the SDK id; a run with no joined id keeps the completion token; the swapped join of two parallel calls of one tool (the known limit) keeps the ids that Router gave and still gives 2 distinct ids.
    - RED: 3 of 4 failed for the expected reason (updates on the completion token). The nil-id test passed at RED: it states the fallback, which is the old behavior.
    - Two existing tests stated the old behavior and changed: `RunProgressTests.aToolTextProgressGoesToTheToolCallOfTheRun` now expects the scripted SDK id `scripted-call-1`, not the completion token. `TranscriptFidelityTests.theRunCodeCallReachesTheWire` took the FIRST update on the runCode id as the `toolCall` creation; now a run update on the same id comes first, so the test finds the update that carries `rawInput`.

    Not done here (out of scope): `TerminalStream` still sends its announce `tool_call_update` on the completion token. New task ^9xk3xf4.

    For ^w7hzpmq: nothing changed in the title rules. Each run update still sends `title: .value(op)`; the SDK `toolCall` update still sends the tool name as title. ^w7hzpmq can now treat the first update on the joined id as the creation.

    Tool note: the `files` tool `edit file` with `replace_all: true` replaced only 1 occurrence for each call on `EventProjection.swift`; I made the other edits one by one and checked with `rg`.
  timestamp: 2026-10-10T16:06:55.662044+00:00
- actor: claude-code
  id: 01m4k92p4kqx8wn762me4yjzeh
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Tests/FoundationModelsACPAgentTests/ToolCallJoinProjectionTests.swift (new, 4 tests), Tests/FoundationModelsACPAgentTests/RunProgressTests.swift, Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift. RED: `swift test --scratch-path .build/alt --force-resolved-versions --filter ToolCallJoinProjectionTests` 3 of 4 failed (updates on the completion token). GREEN: same filter, 4 passed. Full root suite (`SKILLS_MARKETPLACE_CACHE=<empty scratch folder> swift test --scratch-path .build/alt --force-resolved-versions`): first run 871 tests, 2 failures in tests that stated the old id (RunProgressTests, TranscriptFidelityTests), fixed and run once (2 passed); then the full suite one time: 871 tests in 94 suites passed, 1 known issue (the intended withKnownIssue in HarnessSmokeTests). IntegrationTests (`swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions`): 30 tests in 11 suites passed. Only warning in both: the mlx-swift_Cmlx.bundle "missing creator for mutated node" line from a dependency. New task ^9xk3xf4 (TerminalStream). No git stash; bench files not touched; no pin moved; not committed.
    - next: /review. The task stays in `doing`.
  timestamp: 2026-10-10T16:07:02.035355+00:00
- actor: claude-code
  id: 01m4k9czv9pqjm43wfa01hvmqn
  text: |-
    ### test — green
    - evidence: swift test --scratch-path .build/alt --force-resolved-versions (SKILLS_MARKETPLACE_CACHE set to empty scratch folder) — 871 tests in 94 suites passed, 1 known issue (the intended withKnownIssue in HarnessSmokeTests), 0 failures, 0 skipped. swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions — 30 tests in 11 suites passed, 0 failures, 0 skipped. Only warning in both runs: "missing creator for mutated node" under mlx-swift_Cmlx.bundle (the expected mlx-swift dependency warning). No package file warnings.
    - next: none. No code was changed. No process was killed, default .build was not touched, no Package.resolved edit, no commit.
  timestamp: 2026-10-10T16:12:39.657345+00:00
position_column: doing
position_ordinal: '80'
title: Show one tool call for each tool run
---
## Goal

The ACP client must see one `toolCallId` for each tool run. Terminals are out of scope.

## Dependency

This task waits for FoundationModelsRouter task ^xhmws92 (01M4GH48AXA66MP44EGXHMWS92) "Join the SDK tool-call id with the run completion token". It is on the Router board. Do not start before it is on `origin/main` of FoundationModelsRouter.

## Problem

Now the client sees two tool calls for one run:

- the SDK call, in `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift:562-606`
- the run call that is keyed on the completion token, `runCallUpdate`, at `EventProjection.swift:666-684`

## What to change

Use the joined id from the Router, so that both paths send their updates on the same `toolCallId`.

## Acceptance

- [x] One tool run gives exactly one `tool_call` and its `tool_call_update` rows on one `toolCallId`.
- [x] A background run that settles later updates the same `toolCallId`.
- [x] A test reads the wire messages and counts the distinct `toolCallId` values for one run.
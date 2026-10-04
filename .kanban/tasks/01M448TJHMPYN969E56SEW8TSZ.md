---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m44913c1hmrwtnnnm9jd23g7
  text: |-
    Research done.
    - Package.resolved and IntegrationTests/Package.resolved are gitignored. `swift package update FoundationModelsACPClient FoundationModelsACP` moved both pins (client 85c1ddd, wire fe0d82d). The two resolved files now have the same pins.
    - New API: `ConnectionModel.connect(over:logger:bufferLimits:client:)` returns the ClientSideConnection. The `client:` closure wraps the router (`ModelClient`). The router ignores `sessionUpdate`; each SessionModel reads its own subscription.
    - A SessionModel exists only after `ConnectionModel.newSession(_:)` or `resumeSession(_:)`. These send the request through `ClientRequestSpan` (client span + traceparent in `_meta`).
    - The router answers `cancelled` / `cancel` at once for a permission request or an elicitation of a session that is not open in the model. The old SwiftUIACPClient kept them pending for each session id. So a fixture that must see a pending elicitation must open its session through the model.
    - Pending elicitations and their answers moved from the client to `SessionModel` (`pendingElicitations`, `acceptElicitation`, `declineElicitation`). `pendingPermissionRequests` is now `pendingPermissions`. `toolCalls[id]` is now a `ToolCallEntry` in `transcript`.
    - `SessionEntry.Compaction` in CompactionReportTests is the FoundationModelsACP SessionMergeEngine type. It does not change.
  timestamp: 2026-10-04T20:17:33.569475+00:00
- actor: claude-code
  id: 01m44a6hynrhwp3dacckp15xtq
  text: |-
    Implementation landed (not committed).
    - Sources/acp-agent RunPrompt + OutOfProcessPrompt, Examples/acp-print, IntegrationTests SpawnedAgentPromptDrive + StdioContractTests: `ConnectionModel().connect(over:)` in place of `SwiftUIACPClient`. These drivers keep the raw `ClientSideConnection` for each request, so no client span goes on their requests.
    - Discovery: FoundationModelsACP fe0d82d also changed `ClientSideConnection.subscribe(to:).updates` to `AsyncStream<SessionStreamEvent>` (`.update(_)` and `.requestFinished` markers). RunPrompt.collect, acp-print streamAnswer and StdoutFrameChecks.waitForIdle now read `for await case .update(...)` and skip the markers.
    - Harness: `client` is a `ConnectionModel` (HoldingClock injected). makeRecording puts `RecordingClient` in front of the model router with the `client:` closure of `connect(over:client:)`. RecordingClient forwards to `any Client` (the router).
    - Behavior note: the router answers each permission request / elicitation of a session with no SessionModel at once (cancel). So ScriptedPromptFixture and the second session of QueuedScriptedFixture now open their sessions with `harness.client.newSession(_:)` and keep the `SessionModel` (`fixture.session`, `secondSession`). Side effect: that one `session/new` goes through `ClientRequestSpan` (client span + traceparent). All span / metric / content-safety tests stay green.
    - ElicitationPoll takes a `SessionModel`; accept/decline go through `SessionModel`. `newSessionConfigOptions` is read from `session.configOptions` right after `newSession` (the response seeds it).
    - TierTwo: `accumulatedToolCall` reads the `ToolCallEntry` of `session.transcript` into a Sendable snapshot. The model reads its own subscription, so it can lag the collector: `runToolPrompt` now waits with the new `ScriptedPromptFixture.waitForSessionModelIdle()` before it reads the model. The old `waitForCompletedToolCall` had no caller (dead) and is replaced by that wait.
    - HarnessSmokeTests flush test: the chunk now comes from the agent end of the wire to a model-opened session, and the model `updateTap()` proves arrival before the before-flush read. Same assertions.
    - plan.md §16/§20 text updated to name ConnectionModel / SessionModel.
    - `SessionEntry.Compaction` in CompactionReportTests is the wire SessionMergeEngine type; not changed.
  timestamp: 2026-10-04T20:38:00.917553+00:00
- actor: claude-code
  id: 01m44a6m3y779fwnvf280nkvfc
  text: |-
    ### implement — changed
    - evidence: `swift build -c release` rc=0, 0 warnings from this package; `swift test --no-parallel` 737 tests in 83 suites passed (1 known issue = the pre-existing withKnownIssue in HarnessSmokeTests); `swift build --package-path IntegrationTests --build-tests` rc=0. Pins: client 85c1ddd, wire fe0d82d in both gitignored Package.resolved files. 21 files changed (20 tracked + plan.md), nothing committed.
    - next: /review. The last checkbox (CI Build & test and Integration green) needs the commit and the push; it stays open until then.
  timestamp: 2026-10-04T20:38:03.134431+00:00
position_column: doing
position_ordinal: '80'
title: 'Adopt FoundationModelsACPClient 85c1ddd: replace SwiftUIACPClient and ACPSessionState with ConnectionModel and SessionModel'
---
## Problem
CI resolves the sibling packages from main. FoundationModelsACPClient 85c1ddd (commit a65af8a) removes `SwiftUIACPClient`, `ACPSessionState` and `SessionEntry` (of the client). The replacements are `ConnectionModel` and `SessionModel`. This package uses the removed types, so the build fails after the client push. CI run 37228571998 was already red, because the earlier client main used `SessionUpdateAggregator`, which FoundationModelsACP aa1b367 removed.

## Where the old types are used
- Sources/acp-agent/RunPrompt.swift:103, Sources/acp-agent/OutOfProcessPrompt.swift:96
- Examples/acp-print/main.swift:102
- Tests/FoundationModelsACPAgentTestSupport/Harness.swift, RecordingClient.swift
- Tests/FoundationModelsACPAgentTests/Support/ElicitationPoll.swift, Support/ScriptedPromptFixture.swift, ImportSmokeTests.swift:47, Integration/TierTwoTests.swift (doc comment)
- IntegrationTests/.../Support/SpawnedAgentPromptDrive.swift:56, StdioContractTests.swift:223

## Do
- [x] Move the pins in Package.resolved to FoundationModelsACPClient 85c1ddd and FoundationModelsACP main (fe0d82d or later). Align the gitignored IntegrationTests/Package.resolved.
- [x] Read the new `ConnectionModel` and `SessionModel` API in the client checkout. Replace each use of the removed types. Keep the behavior of the tests the same.
- [x] Update the doc comments that name the removed types.
- [x] `swift build -c release` with no warnings from this package. `swift test --no-parallel` green. `swift build --package-path IntegrationTests --build-tests` green.
- [ ] After the push, CI Build & test and Integration are green.

#upstream
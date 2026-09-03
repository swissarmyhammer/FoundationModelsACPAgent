---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1jtcbq9ve5my7fsg1hjah16
  text: |-
    Research results:
    - The `elicitationRequested` arm is not log-only now. Task ^2z6qtqy (commits 2f444c1 and dc3212c) added the `ElicitationRelay` trigger and the `ElicitationRelayTests` suite. I set that work item to done with a note.
    - The `toolCallReport` arm is log-only. `ToolCallReport` (Router checkout, Session/SessionEvent.swift) carries `tool`, `op`, `correlationID` (= the run's `completionToken`), `sessionID`, and `attachments`. Each `ToolCallAttachment` is opaque: `schemaName` + `contentJSON`. The Router reads nothing in it.
    - Wire mapping decision (plan.md §8.4, §11.6): one `tool_call_update` keyed by `correlationID` as the `toolCallId`. Each attachment document becomes one text content item. The parsed documents become `rawOutput` (one value, or an array). The `op` becomes the title. The update makes no status claim: the report does not say how the call ended; `toolStatus` and `runSettled` own that claim. No `locations`: the attachment is an opaque JSON document with no structured path contract, and a location must not come from a rendered string. When a future attachment schema defines structured paths, a follow-up task can map them.
    - A harness test with a scripted attaching tool is not possible: `ToolContext.attach(_:)` is public, but the harness mounts tools only through the loopback MCP test server, and an MCP verb has no path to `attach`. The projection-level synthesized-event test (EventProjectionTests + ProjectionTestSupport pattern) is the test seam.
    - Baseline: 352 tests in 39 suites green at f8bf4c1.
  timestamp: 2026-09-03T05:03:04.937107+00:00
- actor: claude-code
  id: 01m1jtqm28mwg33x24ce9d4xzc
  text: |-
    TDD record:
    - RED: five new tests failed for the correct reason (no `tool_call_update` went out for a `toolCallReport`), one guard test passed as a regression lock.
    - GREEN: the `toolCallReport` arm now sends one `tool_call_update` keyed by the run's `correlationID`. Each attached document is one text content item, the parsed documents ride as `rawOutput` (one value, or an array), and the `op` rides as the title. The update claims no status and no locations. An empty report sends nothing (defensive guard, with a log line). The arm sets `sawOutput`, so a report keeps the honest `end_turn` stop reason.
    - The `rawOutputPatch` logic is shared: `rawOutputPatch(from:)` for segments and `rawOutputPatch(fromDocuments:)` for attachment documents use one implementation.

    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift, Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift
    - next: run the full test suite
    task: ^9vjyddw
  timestamp: 2026-09-03T05:09:13.928008+00:00
- actor: claude-code
  id: 01m1jtrj3mn90gga2e2672mtky
  text: |-
    ### test — green
    - evidence: swift test — 358 passed in 39 suites, 0 failed, 0 skipped, 1 known issue (the expected withKnownIssue in HarnessSmokeTests); swift build — 0 compiler warnings (the mlx-swift bundle "missing creator" note is a pre-existing build-system artifact)
    - next: commit
  timestamp: 2026-09-03T05:09:44.692428+00:00
position_column: doing
position_ordinal: '80'
title: Project the new SessionEvent cases toolCallReport and elicitationRequested to the wire
---
## What
The FoundationModelsRouter update (revision `ba55154`) adds two `SessionEvent` cases:

- `toolCallReport(ToolCallReport)` — the records one tool call attached, keyed by the run's `correlationID` (its `completionToken`). At least one attachment.
- `elicitationRequested(OperationEvent)` — a run asked the user a question through `ToolContext.elicit(_:)` and is suspended until a host answers through `RoutedSession.respond(elicitationId:response:)` or `complete(elicitationId:)`.

`EventProjection.project(_:)` in `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift` now absorbs both cases with log-only arms, so the stream does not break. That is a degradation, not a projection.

## Work
- [x] Decide the wire mapping for `toolCallReport` attachments (plan.md §8.4's vocabulary; possibly `tool_call_update` content items keyed by the run's `correlationID`). Decided: one `tool_call_update` keyed by `correlationID`; each document is one content item; parsed documents ride as `rawOutput`; the `op` is the title; no status claim and no locations (the attachment is opaque).
- [x] Decide the wire mapping for `elicitationRequested` — ACP has a permission/elicitation surface; the answer path needs `RoutedSession.respond(elicitationId:response:)`. Done by task ^2z6qtqy (commits 2f444c1, dc3212c): the `ElicitationRelay` trigger replaced the log-only arm, with the `ElicitationRelayTests` suite.
- [x] Replace the two log-only arms with the real projections and tests. The elicitation arm came with ^2z6qtqy; the `toolCallReport` arm now sends the attachment `tool_call_update`, with five projection tests and one stop-reason test.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
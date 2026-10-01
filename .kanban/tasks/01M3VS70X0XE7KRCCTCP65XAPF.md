---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3vsn4zprhwf83as84023cx4
  text: 'Correction: the Extras commits were rebased and fixed. The pin target is now Extras 50fd4a5 (was b837e56); its parent cdfe98d (was a306b78) holds the TelemetryCapture change of ^rcy24zj.'
  timestamp: 2026-10-01T13:14:57.910273+00:00
- actor: claude-code
  id: 01m3vvajj4fvcgd5bxayh05vwj
  text: |-
    Research:
    - Pin: `swift package update FoundationModelsExtras` in the root and in IntegrationTests/. Both Package.resolved files show revision 50fd4a5aeac0aede8f4e3d4783946c7afa1af784. The two Package.resolved files are in .gitignore, thus git shows no diff for them.
    - `ExtrasTelemetry` and `ExtrasTelemetry.errorType(of:)` are internal in Extras 50fd4a5 (the enum has no `public`). The agent cannot call it. The agent keeps `ACPAgentTelemetry.errorTypeName(of:)` (type name only) for the spans that it ends itself.
    - The card says that the command span goes through `TracedCall.run`. It does not: `CommandDispatch` uses `AgentTracing.withSpan`, which calls `Tracer.withSpan` of swift-distributed-tracing. `Tracer.withSpan` calls `span.recordError(error)` when the body throws. `RequestTracing.withRequestSpan` (initialize, session/cancel) uses `Tracer.withSpan` too. Thus the pin move alone does not remove the recorded error of the command span. The agent must open these spans itself and set only the error status and `error.type`.
    - Spans through `TracedCall.run`: `AgentTracing.withEnteredSpan` (MCP connect, elicitation) and `RequestTracing.withEnteredRequestSpan` (session/new, session/resume). Extras writes `error.type` after the body, thus the agent write in `recordingErrorType` there is overwritten and has no effect. Remove it.
    - The content-safety test has no command error now (`/help` does not fail), and its MCP connect error does not hold a marker. The test must get a failing command whose error description holds a marker, and an http URL that holds a marker.
  timestamp: 2026-10-01T13:44:08.516393+00:00
- actor: claude-code
  id: 01m3vvpb3xssx9pbzdw3bx8h3e
  text: |-
    Implementation:
    - Pin: root and IntegrationTests/ Package.resolved show FoundationModelsExtras 50fd4a5aeac0aede8f4e3d4783946c7afa1af784 (no local path override).
    - `AgentTracing.withSpan(_:context:ofKind:_:)` now opens the span with `startSpan`, not with `Tracer.withSpan`. `Tracer.withSpan` calls `recordError` on each body error. On an error the span gets only the error status and `error.type`. `RequestTracing.withRequestSpan` uses it with kind `.server`.
    - `AgentTracing.recordFailure(of:on:)` (was `recordErrorType`) sets the error status and `error.type`. `RequestTracing.endRequestSpan(_:throwing:)` calls it and calls no `recordError`.
    - `AgentTracing.recordingErrorType` is removed. `withEnteredSpan` and `withEnteredRequestSpan` pass the body to `TracedCall.run`, which writes `error.type` itself.
    - Decision for item 4: `ExtrasTelemetry.errorType(of:)` is internal in Extras 50fd4a5, thus the agent cannot call it. The agent keeps `ACPAgentTelemetry.errorTypeName(of:)` (type name only) for the spans that it ends itself (command, initialize, session/cancel, prompt). The spans through `TracedCall.run` (MCP connect, elicitation, session/new, session/resume) get the Extras value. If Extras makes `errorType(of:)` public later, the agent can use it in `recordFailure` and in `ACPAgentTelemetry.errorMetadata`.
    - Content-safety test: the fixture registers a `.rendered` command `/fail` whose render throws an error that holds the argument marker, and the http MCP server URL holds a path marker. The test expects that the client error description holds each marker, and `TelemetryCapture.run(forbidding:)` proves that no span, log record or metric holds them. RED before the fix: the command span and the prompt span held the marker in a recorded error. `leaksInSpanDetails(of:)`, its helpers and `spanDetailReaderSeesEachAttribute` are removed.
    - `ScriptedPromptFixture.make` got a `commandProviders:` parameter (default empty).
  timestamp: 2026-10-01T13:50:34.109499+00:00
- actor: claude-code
  id: 01m3vvph6942mrn4h792fzeypb
  text: |-
    ### implement — changed
    - evidence: `swift test` (root): 669 tests in 77 suites passed, 0 failures, 1 known issue (the existing `withKnownIssue` in HarnessSmokeTests); no compiler warning (only the known "missing creator ... mlx-swift_Cmlx.bundle" line). `swift build --build-tests` in IntegrationTests/: Build complete, no warning. Files: Sources/FoundationModelsACPAgent/Telemetry/AgentTracing.swift, Sources/FoundationModelsACPAgent/Telemetry/RequestTracing.swift, Sources/FoundationModelsACPAgent/Commands/CommandDispatch.swift (doc), Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift (doc), Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift, Tests/FoundationModelsACPAgentTests/AgentSpanTests.swift, Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift, Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift; Package.resolved and IntegrationTests/Package.resolved (gitignored) at Extras 50fd4a5.
    - next: review
  timestamp: 2026-10-01T13:50:40.329485+00:00
- actor: claude-code
  id: 01m3vw7mkh9y8b9h5m5tjgqyjs
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 7cf7df9), backend local. 0 findings, 0 confirmed, 0 refuted. 8 files reviewed, 0 failed. The .reviewignore rule excluded 4 .kanban/ files. The task has no earlier review findings.
    - next: none. The task moved to done.
  timestamp: 2026-10-01T14:00:00.881038+00:00
depends_on:
- 01M3QYS1Y5K4WBGTN73Z7ZAQG4
position_column: done
position_ordinal: ff8b80
title: 'After the Extras pin moves to b837e56: adopt the safe error record of TracedCall.run in the agent'
---
## Why
Extras commit b837e56 (card ^z7zaqg4) changes `TracedCall.run`. When the body throws, the span gets the error status and `error.type` only. The span records no error with `recordError`, because swift-otel exports the error description as `exception.message`, and a description can hold content.

The agent has two items that this change touches:
- `RequestTracing.endRequestSpan(_:throwing:)` calls `span.recordError(error)` itself. This is the same leak as the one that b837e56 removes from Extras.
- `AgentSpanTests` expects `commandSpan.errors.count == 1` and `connectSpan.errors.count == 1`. These spans go through `TracedCall.run`, thus the count becomes 0 when the pin moves.

## What
- [x] Move the Extras pin to b837e56 or later (after the user pushes it).
- [x] `RequestTracing.endRequestSpan(_:throwing:)`: set the error status and `error.type` only. Do not call `recordError(error)`.
- [x] `AgentSpanTests` and `RequestTracingTests`: read the error status and `error.type` in place of `span.errors`.
- [x] `AgentTracing.recordingErrorType` writes `error.type` as the type name only. Extras `TracedCall.run` now writes the same key, with the enum case name when reflection shows one, after the body ends. Decide if the agent keeps its own write or uses the Extras value.
- [x] Remove `leaksInSpanDetails(of:)` from `TelemetryContentSafetyTests` (item 3 of ^rcy24zj).

## Acceptance Criteria
- [x] A request, command or MCP connect error whose description holds content reaches no span, log record or metric, and `TelemetryCapture.run(forbidding:)` proves it.

#otel
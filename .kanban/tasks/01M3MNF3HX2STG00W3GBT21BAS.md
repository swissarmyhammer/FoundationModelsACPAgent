---
comments:
- actor: claude-code
  id: 01m3qp0dx2n977b3vdgqvfw45n
  text: |-
    Research (implement). The card is older than the code. These facts change the plan:

    - The handlers now live in `Agent/PromptExecution.swift` (`prompt`, `sessionCancel`), `Agent/Initialization.swift`, `Agent/SessionSetup.swift` and `Agent/SessionResume.swift`. There is no `PromptTurn.swift`.
    - `prompt(_:)` returns `{}` at once. The model work runs after the response, in a hook of `afterRespondingToCurrentRequest`. The hooks run in the dispatch task of the connection, after the handler returned, so a task-local `ServiceContext` of the handler does NOT reach them. The prompt span must stay open across the hook, and the hook must bind the span context itself.
    - Router captures `ServiceContext.current` when a message goes into the session queue (`RoutedSessionActorGeneration`, `RoutedSessionActorQueueing`) and opens the submission span with that context as parent (`beginSubmission`). Thus a Router call made inside the prompt span context gives a child submission span. No Router change is necessary.
    - `TracedCall.run` (Extras 3de1179) ends its span when its body returns. It fits `session/new` and `session/resume`. It cannot hold the prompt span, because the prompt span must stay open after the handler returns. Router has the same case for its submission span and writes the same "enter" record itself (`RouterTelemetry.EnterRecord.write(for:named:tracer:to:)`) with the public `SpanIdentity(context:tracer:)` and `TracedCall.enterLevel`. The prompt uses that same shape. Extras has no public writer of the "enter" record for a span that `startSpan` opened; an Extras API for it would remove the copy in Router and here.
    - `withSpan` and `TracedCall.run` call `span.recordError(error)` and set the error status. The helper adds `error.type` (the type name only).
    - `TelemetryCapture.Context.spans` gives `FinishedInMemorySpan` values with `kind`, `traceID`, `spanID` and `parentSpanID`. The test target must link the `Tracing` and `InMemoryTracing` products to read them.
    - The pinned Extras (3de1179) is newer than 70ad74d and has no newer commit on origin/main, so `swift package update` is not necessary.
  timestamp: 2026-09-29T22:54:15.458916+00:00
- actor: claude-code
  id: 01m3qps6mrt2smyg13tpqbes8n
  text: |-
    Implementation landed (not committed).

    - New `Telemetry/RequestTracing.swift`: `withRequestSpan` (`initialize`, `session/cancel`), `withEnteredRequestSpan` over `TracedCall.run` (`session/new`, `session/resume`), and `startRequestSpan` / `endRequestSpan` / `endPromptSpan` for the prompt. Each span is `.server`, carries `acp.method` and `session.id` (for `session/new`, the id of the new session after it exists), and on a thrown error records the error, the error status and `error.type` (type name only). `AgentSideConnection.afterRespondingInCurrentServiceContext` carries the `ServiceContext` of the handler into the deferred prompt work.
    - `prompt(_:)` opens the span, runs the acceptance in the span context, and registers one more after-response hook that ends the span with the stop reason. `PromptStateOwner.stopReason` replaces the `didEnd` flag (one source of truth).
    - Vocabulary: `ACPAgentTelemetry.errorTypeName(of:)` (shared with `errorMetadata`), `enterMessage(forSpanNamed:)`, `LogMetadataKey.traceId` / `spanId`. The `periphery:ignore` on `tracer(explicit:)` is gone, because it has callers now. `ACPMethod.initialize` / `sessionCancel` added.
    - Discovery: the card's claim that the task-local tracer of `TelemetryCapture` reaches the Router spans is wrong. The Router pump is a `Task.detached`. The first GREEN attempt had zero submission spans in the capture. Fix in the test wiring only: `EchoModel.makeRouter(..., tracer:)`, `makeStubAgent(..., tracer:)` and `ScriptedPromptFixture.make(..., tracer:)`; the test gives `context.tracer`. The test support target and the unit test target now link the `Tracing` product; the test target also links `InMemoryTracing`.
    - `RequestError` is a typealias of `FoundationModelsACP.ACPError`, so `error.type` is `FoundationModelsACP.ACPError`. The test reads the name with `String(reflecting: RequestError.self)`.
    - Known limit: if the connection closes before the `{}` response goes out, the connection runs no deferred work, so the prompt span does not end (the "enter" record shows it). This is the same rule that skips the prompt work.
    - Periphery (retain-public, tests excluded from the report): no finding in the changed files.
  timestamp: 2026-09-29T23:07:47.224709+00:00
- actor: claude-code
  id: 01m3qps9w8azctxjxm3cdkgxz6
  text: |-
    ### implement — changed
    - evidence: `swift test --filter RequestTracingTests` 7/7 pass; `swift test` 651 tests in 73 suites pass (1 known issue, the existing `withKnownIssue` in HarnessSmokeTests), zero compiler warnings; `swift build --build-tests` in IntegrationTests/ clean. Files: Package.swift, Sources/FoundationModelsACPAgent/Telemetry/RequestTracing.swift (new), Telemetry/ACPAgentTelemetry.swift, Agent/Initialization.swift, Agent/SessionSetup.swift, Agent/SessionResume.swift, Agent/PromptExecution.swift, Agent/PromptState.swift, Commands/CommandDispatch.swift, Configuration/EchoModel.swift, RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTestSupport/StubProfileFixtures.swift, Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift, Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift (new).
    - next: /review
  timestamp: 2026-09-29T23:07:50.536708+00:00
- actor: claude-code
  id: 01m3qqehtn60g5chza7v1jven9
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 12788a5); 1 finding (1 confirmed, 1 refuted) — Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift:218 (completeness/invariant-propagation)
    - next: give `tracer: context.tracer` to each fixture that a test makes in a `TelemetryCapture.run` context in RequestTracingTests.swift, then do the review again.
  timestamp: 2026-09-29T23:19:26.805105+00:00
- actor: claude-code
  id: 01m3qqevqq9mzx1193gahnmvnh
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 14 files (2 new)
    - test: green — swift test 651 tests pass; IntegrationTests build ok
    - commit: 12788a5
    - review: findings — Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift:218
  timestamp: 2026-09-29T23:19:36.951516+00:00
- actor: claude-code
  id: 01m3qqn3277a057zvjxqc5rza8
  text: |-
    Finding corrected (RequestTracingTests.swift:218, completeness/invariant-propagation). The same cause was in two capture blocks: `sessionResumeRecordsOneServerSpanAndOneEnterRecord` and `promptForAnUnknownSessionRecordsTheErrorOnItsSpan`. Both made the fixture without the capture tracer.

    Fix: a new private helper `makeTracedFixture(script:context:)` makes the fixture with `tracer: context.tracer`. All three capture blocks of the file (`runOnePrompt` and the two cases) use it now. The helper doc comment holds the reason (the Router pump is a detached task and gets no task-local tracer), so no capture block can skip the tracer.

    Other files: no other test file reads spans from a `TelemetryCapture`. The other captures (SessionSurfaceLoggingTests, ElicitationRelayTests, MCPCompositionTests, and more) read log records only, so the cause does not apply to them.
  timestamp: 2026-09-29T23:23:01.063696+00:00
- actor: claude-code
  id: 01m3qqn4tkesankbve8s2hxapb
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift; `swift test --filter RequestTracingTests` 7/7 pass; `swift test` 651 tests in 73 suites pass (1 known issue, the existing `withKnownIssue` in HarnessSmokeTests), zero compiler warnings.
    - next: /review
  timestamp: 2026-09-29T23:23:02.867240+00:00
- actor: claude-code
  id: 01m3qqy314rbq32qvwgax281n4
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit b4acf84). 0 findings, 0 confirmed, 0 refuted. 7 validators ran, 0 failed. 1 file was reviewed: Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift. All items in the prior `## Review Findings` section are checked.
    - next: none. The task is in done.
  timestamp: 2026-09-29T23:27:55.940007+00:00
- actor: claude-code
  id: 01m3qqyctc45hba6pk1kw82jqn
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — RequestTracingTests.swift
    - test: green — swift test 651 tests pass
    - commit: b4acf84
    - review: clean — zero findings; task moved to done
  timestamp: 2026-09-29T23:28:05.964378+00:00
depends_on:
- 01M3MNAKQT4H82BNG84PE7PD6X
- 01M3MNC26MHCGN4R7BVKFQVQQB
position_column: done
position_ordinal: ff8180
title: 'OTel 6: a server span for each ACP request, so the Router spans have a parent'
---
## What
Now the Router submission spans have no parent, because the agent opens no span for an ACP request. Open one server span for each ACP request, so that the Router spans (`FoundationModelsRouter.submission`, `.session`, `.compact`, `.fork`) become its children. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md` (items 1, 3, 4, 8).

The trace context of the incoming `_meta` is a different task (OTel 7). In this task, the server span starts a new trace or uses the current `ServiceContext`.

- [x] Create `Sources/FoundationModelsACPAgent/Telemetry/RequestTracing.swift` with a helper, for example `func withRequestSpan<T>(_ name: String, method: String, sessionId: SessionId?, _ body: (any Span) async throws -> T) async rethrows -> T`. It opens the span with `ofKind: .server` through `ACPAgentTelemetry.tracer(explicit:)`, sets `acp.method` and `session.id`, records a thrown error (`error.type` is the error type name, never the message), and ends the span.
- [x] Hang detection (design item 8): a request that can suspend for a long time also writes one "enter" log record when it starts. Use `TracedCall.run`, the span-plus-enter helper of FoundationModelsExtras (Extras card ^ykgz2aa, 01M3MN91YK71YVJ9C7WYKGZ2AA). It reads the trace id and span id for the "enter" record from the `traceparent` that the tracer injects.
  - Note (implement): `session/new` and `session/resume` use `TracedCall.run`. The prompt span must stay open after the handler returns `{}`, and `TracedCall.run` ends its span when its body returns. Thus the prompt writes the same record itself with the public `SpanIdentity(context:tracer:)` and `TracedCall.enterLevel`, as Router does for its submission span.

Extras: FoundationModelsExtras OTel A to D are on Extras origin/main (HEAD 70ad74d, 2026-09-28). Run `swift package update FoundationModelsExtras` before you start this task.
  - Note (implement): the pin is 3de1179, which is newer than 70ad74d, and origin/main has no newer commit.
- [x] Wrap these handlers with the helper:
  - `initialize(_:)` in `Sources/FoundationModelsACPAgent/Agent/Initialization.swift`.
  - `newSession(_:)` in `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift` (with "enter" log: it resolves tools and MCP servers).
  - `resumeSession(_:)` in `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` (with "enter" log). This agent has no `session/load` handler; `session/resume` takes its place.
  - `prompt(_:)` and `sessionCancel(_:)` in `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift` (the prompt span has an "enter" log). The prompt span stays open until the prompt response is sent, and it sets `prompt.stop_reason`.
  - Note (implement): the file is now `Agent/PromptExecution.swift`. The prompt returns `{}` at once, and the stop reason goes out in the `idle` update after the work. The prompt span ends after that work, with the stop reason of the `idle` update.
- [x] Make sure the Router calls in the prompt run inside the span's `ServiceContext`, so that the Router spans are its children. If a turn runs in a detached `Task`, carry the context into it with `ServiceContext.withValue` / `withSpan`.
- [x] Span attributes carry only ids, names, counts and the stop reason (design item 4).

## Acceptance Criteria
- [x] The prompt, `session/new` and `session/resume` each write one "enter" log record when they start. (The check of its ids is in task OTel 6b ^naf9z8b.)
- [x] In a `TelemetryCapture`, one prompt through the harness records one `FoundationModelsACPAgent.prompt` span of kind `.server`, and each `FoundationModelsRouter.submission` span of that prompt has the prompt span as its parent (same trace id, parent span id equal to the prompt span id).
- [x] `initialize`, `session/new`, `session/resume` and `session/cancel` each record one span with its `SpanName` and `acp.method`.
- [x] A prompt that throws (for example `unknownSession`) records the error on the span and ends the span.

## Tests
- [x] Add `Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift`. Use `TelemetryCapture` from Extras `TelemetryTestSupport` with the test rules in OTel 3 (its task-local `withTracer`; no `InstrumentationSystem.bootstrap`). Drive initialize, session/new, one prompt with `ScriptedModel`, and session/cancel through `Tests/FoundationModelsACPAgentTestSupport/Harness.swift`, all inside the capture. Assert the span names, kinds, attributes and the parent link of the Router submission span.
- [x] The Router spans go to the same capture: `InstrumentationSystem.tracer` checks the task-local instrument first (`_findInstrument` in swift-distributed-tracing), and `RouterTracing.tracer(explicit: nil)` reads it at call time. The parent-link assertion above proves this; no Router change is necessary.
  - Note (implement): the task-local tracer does NOT reach the Router spans. A Router session does its work in a `Task.detached` pump, which gets no task-local value. The test gives the tracer of the capture to the Router explicitly (`EchoModel.makeRouter(..., tracer:)`, `makeStubAgent(..., tracer:)`). No Router change is necessary. In production, `acp-agent` bootstraps the tracer globally, so the pump reads it.
- [x] In this task, assert only that the "enter" record exists. Task OTel 6b ^naf9z8b adds the id checks. (Extras OTel E ^wts388b is on origin/main: `TelemetryCapture.Context.tracer` is a `W3CInMemoryTracer`; code that needs the `InMemoryTracer` type uses `context.tracer.inMemoryTracer`.)
- [x] Run `swift test --filter RequestTracingTests`. Expected: pass.
- [x] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel

## Review Findings (2026-09-29 18:09)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 14 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift:218` `completeness/invariant-propagation` — All fixture creation calls within a `TelemetryCapture.run` context must pass `tracer: context.tracer` to ensure Router spans are captured in the local tracing context, not the global tracer. The documentation at lines 112–115 and the pattern at line 115 (`runOnePrompt()`) make this explicit: Router runs in a detached task and does not inherit the task-local tracer. This test creates a fixture without the tracer parameter. Change line 218 to: `let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.fixtureLabel, tracer: context.tracer)`.

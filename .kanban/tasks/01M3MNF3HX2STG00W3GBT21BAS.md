---
depends_on:
- 01M3MNAKQT4H82BNG84PE7PD6X
- 01M3MNC26MHCGN4R7BVKFQVQQB
position_column: todo
position_ordinal: '9080'
title: 'OTel 6: a server span for each ACP request, so the Router spans have a parent'
---
## What
Now the Router submission spans have no parent, because the agent opens no span for an ACP request. Open one server span for each ACP request, so that the Router spans (`FoundationModelsRouter.submission`, `.session`, `.compact`, `.fork`) become its children. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md` (items 1, 3, 4, 8).

The trace context of the incoming `_meta` is a different task (OTel 7). In this task, the server span starts a new trace or uses the current `ServiceContext`.

- [ ] Create `Sources/FoundationModelsACPAgent/Telemetry/RequestTracing.swift` with a helper, for example `func withRequestSpan<T>(_ name: String, method: String, sessionId: SessionId?, _ body: (any Span) async throws -> T) async rethrows -> T`. It opens the span with `ofKind: .server` through `ACPAgentTelemetry.tracer(explicit:)`, sets `acp.method` and `session.id`, records a thrown error (`error.type` is the error type name, never the message), and ends the span.
- [ ] Hang detection (design item 8): a request that can suspend for a long time also writes one "enter" log record when it starts. Use `TracedCall.run`, the span-plus-enter helper of FoundationModelsExtras (Extras card ^ykgz2aa, 01M3MN91YK71YVJ9C7WYKGZ2AA). It reads the trace id and span id for the "enter" record from the `traceparent` that the tracer injects.

Extras: FoundationModelsExtras OTel A to D are on Extras origin/main (HEAD 70ad74d, 2026-09-28). Run `swift package update FoundationModelsExtras` before you start this task.
- [ ] Wrap these handlers with the helper:
  - `initialize(_:)` in `Sources/FoundationModelsACPAgent/Agent/Initialization.swift`.
  - `newSession(_:)` in `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift` (with "enter" log: it resolves tools and MCP servers).
  - `resumeSession(_:)` in `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` (with "enter" log). This agent has no `session/load` handler; `session/resume` takes its place.
  - `prompt(_:)` and `sessionCancel(_:)` in `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift` (the prompt span has an "enter" log). The prompt span stays open until the prompt response is sent, and it sets `prompt.stop_reason`.
- [ ] Make sure the Router calls in the prompt run inside the span's `ServiceContext`, so that the Router spans are its children. If a turn runs in a detached `Task`, carry the context into it with `ServiceContext.withValue` / `withSpan`.
- [ ] Span attributes carry only ids, names, counts and the stop reason (design item 4).

## Acceptance Criteria
- [ ] The prompt, `session/new` and `session/resume` each write one "enter" log record when they start. (The check of its ids is in task OTel 6b ^naf9z8b.)
- [ ] In a `TelemetryCapture`, one prompt through the harness records one `FoundationModelsACPAgent.prompt` span of kind `.server`, and each `FoundationModelsRouter.submission` span of that prompt has the prompt span as its parent (same trace id, parent span id equal to the prompt span id).
- [ ] `initialize`, `session/new`, `session/resume` and `session/cancel` each record one span with its `SpanName` and `acp.method`.
- [ ] A prompt that throws (for example `unknownSession`) records the error on the span and ends the span.

## Tests
- [ ] Add `Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift`. Use `TelemetryCapture` from Extras `TelemetryTestSupport` with the test rules in OTel 3 (its task-local `withTracer`; no `InstrumentationSystem.bootstrap`). Drive initialize, session/new, one prompt with `ScriptedModel`, and session/cancel through `Tests/FoundationModelsACPAgentTestSupport/Harness.swift`, all inside the capture. Assert the span names, kinds, attributes and the parent link of the Router submission span.
- [ ] The Router spans go to the same capture: `InstrumentationSystem.tracer` checks the task-local instrument first (`_findInstrument` in swift-distributed-tracing), and `RouterTracing.tracer(explicit: nil)` reads it at call time. The parent-link assertion above proves this; no Router change is necessary.
- [ ] The "enter" record ids come from the W3C `traceparent` that the tracer injects. The `TelemetryCapture` tracer is an `InMemoryTracer`: it injects only its own trace-id and span-id keys, not W3C `traceparent`, so its "enter" records have no ids. In this task, assert only that the "enter" record exists. Task OTel 6b ^naf9z8b adds the id checks after Extras OTel E ^wts388b is on Extras origin/main.
- [ ] Run `swift test --filter RequestTracingTests`. Expected: pass.
- [ ] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
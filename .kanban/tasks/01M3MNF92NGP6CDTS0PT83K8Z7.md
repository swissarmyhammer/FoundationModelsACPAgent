---
comments:
- actor: claude-code
  id: 01m3qr0v26j25e99v8bdgzvxpq
  text: |-
    Research:
    - The dependencies are current. `.build/checkouts/FoundationModelsACP` is at acf7700 and has `Core/TraceContextMeta.swift` (`TraceContextMeta.extract(from:)` gives `nil` for no `_meta`, no `traceparent` string, or a bad `traceparent`). Extras is at 3de1179 and has `W3CInMemoryTracer` in `TelemetryTestSupport`. No `swift package update` is necessary.
    - `ExtrasTelemetry.TraceContextField` is internal. The public names are `SpanIdentity.traceparentField` and `SpanIdentity.tracestateField`. The agent uses these for the carrier keys.
    - `InstrumentationSystem.instrument` gives the task-local instrument of `withTracer` first. Thus in the tests it is the tracer of the capture, the same tracer that `ACPAgentTelemetry.tracer(explicit: nil)` gives.
    - `TracedCall.run` has no `context` parameter. `withEnteredRequestSpan` must run it inside `ServiceContext.withValue(<extracted context>)`.
    - The prompt and cancel spans open in `Agent/PromptExecution.swift`, not in `PromptTurn.swift` (the card is older than the code).
    - All five request types (`InitializeRequest`, `NewSessionRequest`, `ResumeSessionRequest`, `PromptRequest`, `CancelSessionNotification`) have `meta: JSONValue?`.
  timestamp: 2026-09-29T23:29:26.086774+00:00
- actor: claude-code
  id: 01m3qrddb94nxwa41g0tavg5rk
  text: |-
    Implementation landed (TDD).
    - RED: 4 new cases in `RequestTracingTests`. The good-`traceparent` case and the case for `initialize`, `session/new`, `session/resume` and `session/cancel` failed because the span had a new trace id and no parent. The bad-value case and the no-`_meta` case passed before the change. They guard the old behavior, as the acceptance criteria ask.
    - GREEN: `RequestTracing` now takes `meta: JSONValue?` in `withRequestSpan`, `withEnteredRequestSpan` and `startRequestSpan`. The private `parentContext(meta:)` reads the `_meta` with `TraceContextMeta.extract(from:)`. The private `TraceContextMetaExtractor` then gives the two strings to `InstrumentationSystem.instrument.extract`, under `SpanIdentity.traceparentField` and `SpanIdentity.tracestateField`. These are the public aliases of the internal `ExtrasTelemetry.TraceContextField`. `withEnteredRequestSpan` runs `TracedCall.run` inside `ServiceContext.withValue(parentContext)`, because `TracedCall.run` has no `context` parameter.
    - No `_meta`, or a bad `traceparent`: the codec gives `nil`, and the current `ServiceContext` stays with no change. The request does not fail.
    - The five handlers pass `params.meta`. The prompt and the cancel handlers are in `Agent/PromptExecution.swift`, not in `PromptTurn.swift`.
    - No `swift package update` was necessary. The checkouts already hold ACP acf7700 and Extras 6c399a4 (Extras HEAD 3de1179 descends from 6c399a4).
    - No content goes into span attributes. Only the ids and the `tracestate` from the client go into the span context.
  timestamp: 2026-09-29T23:36:18.025265+00:00
- actor: claude-code
  id: 01m3qrdgnmtcghsjtr42gnfy0h
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/Telemetry/RequestTracing.swift, Sources/FoundationModelsACPAgent/Agent/Initialization.swift, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/Agent/SessionResume.swift, Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift, Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift. `swift test --filter RequestTracingTests`: 11/11 pass. `swift test`: 655 tests pass (651 + 4 new), 0 failures, 1 known issue that already existed (HarnessSmokeTests withKnownIssue), no compiler warnings. `swift build --build-tests` in IntegrationTests/: build complete, no compiler warnings.
    - next: /review
  timestamp: 2026-09-29T23:36:21.428903+00:00
depends_on:
- 01M3MNF3HX2STG00W3GBT21BAS
position_column: doing
position_ordinal: '80'
title: 'OTel 7: take the parent trace context from the traceparent in the incoming ACP _meta'
---
## What
Design item 7: W3C `traceparent` and `tracestate` cross the ACP boundary in `_meta`. When a client sends them in the `_meta` of a request, the server span of OTel 6 must use that context as its parent. Then the client trace and the agent trace are one trace. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md`.

External dependency: FoundationModelsACP card ^ywrxe73 (01M3MNFSYH7WNP58CCJYWRXE73), "OTel: add a codec that reads and writes W3C traceparent and tracestate in an ACP _meta object". It adds `Core/TraceContextMeta.swift` in FoundationModelsACP. `traceparent` and `tracestate` are plain string keys at the top level of `_meta`. The codec has no Tracing or Instrumentation dependency. A task cannot depend on a task on a different board, so this link is text only. The codec is on FoundationModelsACP origin/main (acf7700, 2026-09-28): update the FoundationModelsACP dependency first. Do not write a second codec here. Note: the local `Package.resolved` pins the family packages to old revisions, and a newer Extras (needed for `TelemetryCapture`) does not build with the pinned Router (see ^kfqvqqb). This task also waits for OTel 6 on this board.

- [x] In `Sources/FoundationModelsACPAgent/Telemetry/RequestTracing.swift` (OTel 6), give the helper the request's `_meta`. Read the `traceparent` and `tracestate` strings with the FoundationModelsACP codec (`TraceContextMeta`).
- [x] The codec does not know Instrumentation, so add a small `Extractor` in `RequestTracing.swift` that gives those two strings to `InstrumentationSystem.instrument.extract(_:into:using:)`, under the field names `ExtrasTelemetry` gives for `traceparent` and `tracestate`. Open the server span with the extracted `ServiceContext` as its parent.
- [x] Do not write a second `traceparent` parser in the agent. Where the agent must read ids, use the public `SpanIdentity` of FoundationModelsExtras (`Sources/FoundationModelsExtras/Telemetry/SpanIdentity.swift`) and the `ServiceContext` values `w3cTraceFlags` and `w3cTraceState`.
- [x] Pass the `_meta` from each wrapped handler: `initialize`, `newSession`, `resumeSession`, `prompt`, `sessionCancel` (files: `Agent/Initialization.swift`, `Agent/SessionSetup.swift`, `Agent/SessionResume.swift`, `Agent/PromptTurn.swift`).
- [x] A request with no `_meta`, or with a `traceparent` that does not parse, starts a new trace and does not fail the request.
- [x] MCP request `_meta` (the outbound side of design item 7) is not in this task. The MCP client is in FoundationModelsMultitool.

## Acceptance Criteria
- [x] A `session/prompt` request whose `_meta` has `traceparent: 00-<trace-id>-<span-id>-01` records a prompt span with that trace id and with that span id as its parent.
- [x] A request with a bad `traceparent` value gets a normal response, and its span has a new trace id.
- [x] A request with no `_meta` behaves as before OTel 7.

## Tests
- [x] Extras OTel E ^wts388b is on Extras origin/main (6c399a4). Run `swift package update FoundationModelsExtras`. `TelemetryCapture.Context.tracer` is a `W3CInMemoryTracer`: it injects and extracts `traceparent` and `tracestate`, and an invalid value gives no remote context. Use it for these tests.
- [x] Add cases to `Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift` (from OTel 6): one with a good `traceparent`, one with a bad value, one with no `_meta`. The harness in `Tests/FoundationModelsACPAgentTestSupport/Harness.swift` builds the requests; set `_meta` on the `PromptRequest` it sends.
- [x] Run `swift test --filter RequestTracingTests`. Expected: pass.
- [x] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
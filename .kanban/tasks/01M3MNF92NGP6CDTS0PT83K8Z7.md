---
depends_on:
- 01M3MNF3HX2STG00W3GBT21BAS
position_column: todo
position_ordinal: '9180'
title: 'OTel 7: take the parent trace context from the traceparent in the incoming ACP _meta'
---
## What
Design item 7: W3C `traceparent` and `tracestate` cross the ACP boundary in `_meta`. When a client sends them in the `_meta` of a request, the server span of OTel 6 must use that context as its parent. Then the client trace and the agent trace are one trace. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md`.

External dependency: FoundationModelsACP card ^ywrxe73 (01M3MNFSYH7WNP58CCJYWRXE73), "OTel: add a codec that reads and writes W3C traceparent and tracestate in an ACP _meta object". It adds `Core/TraceContextMeta.swift` in FoundationModelsACP. `traceparent` and `tracestate` are plain string keys at the top level of `_meta`. The codec has no Tracing or Instrumentation dependency. A task cannot depend on a task on a different board, so this link is text only. Do not start this task until that codec is on FoundationModelsACP `main`. Do not write a second codec here.

- [ ] In `Sources/FoundationModelsACPAgent/Telemetry/RequestTracing.swift` (OTel 6), give the helper the request's `_meta`. Read the `traceparent` and `tracestate` strings with the FoundationModelsACP codec (`TraceContextMeta`).
- [ ] The codec does not know Instrumentation, so add a small `Extractor` in `RequestTracing.swift` that gives those two strings to `InstrumentationSystem.instrument.extract(_:into:using:)`. Open the server span with the extracted `ServiceContext` as its parent.
- [ ] Pass the `_meta` from each wrapped handler: `initialize`, `newSession`, `resumeSession`, `prompt`, `sessionCancel` (files: `Agent/Initialization.swift`, `Agent/SessionSetup.swift`, `Agent/SessionResume.swift`, `Agent/PromptTurn.swift`).
- [ ] A request with no `_meta`, or with a `traceparent` that does not parse, starts a new trace and does not fail the request.
- [ ] MCP request `_meta` (the outbound side of design item 7) is not in this task. The MCP client is in FoundationModelsMultitool.

## Acceptance Criteria
- [ ] A `session/prompt` request whose `_meta` has `traceparent: 00-<trace-id>-<span-id>-01` records a prompt span with that trace id and with that span id as its parent.
- [ ] A request with a bad `traceparent` value gets a normal response, and its span has a new trace id.
- [ ] A request with no `_meta` behaves as before OTel 7.

## Tests
- [ ] The extract step needs an instrument that reads W3C `traceparent`. The `TelemetryCapture` tracer is an `InMemoryTracer`: it injects and extracts only its own trace-id and span-id keys, not W3C `traceparent`. Blocker: the FoundationModelsExtras task that adds a W3C-capable tracer to `TelemetryTestSupport` Extras OTel E ^wts388b (01M3MV1R3D52RAMFNFKWTS388B); with it, `TelemetryCapture` binds by default a tracer that records spans and injects and extracts `traceparent` and `tracestate`. Do not start this task until that tracer is on Extras origin/main.
- [ ] Add cases to `Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift` (from OTel 6): one with a good `traceparent`, one with a bad value, one with no `_meta`. The harness in `Tests/FoundationModelsACPAgentTestSupport/Harness.swift` builds the requests; set `_meta` on the `PromptRequest` it sends.
- [ ] Run `swift test --filter RequestTracingTests`. Expected: pass.
- [ ] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
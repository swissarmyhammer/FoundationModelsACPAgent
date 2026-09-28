---
depends_on:
- 01M3MNF3HX2STG00W3GBT21BAS
- 01M3MNF9A7FRPJJ3JZA503GB5G
position_column: todo
position_ordinal: '9680'
title: 'OTel 6b: add the enter record id checks of OTel 6 and OTel 8'
---
## What
OTel 6 (^bt21bas) and OTel 8 (^503gb5g) write an "enter" log record when a long call starts (design item 8), through `TracedCall.run` of FoundationModelsExtras. `TracedCall.run` reads the trace id and span id of that record from the W3C `traceparent` that the tracer injects. The current `TelemetryCapture` tracer is an `InMemoryTracer`, which does not inject W3C `traceparent`. So OTel 6 and OTel 8 check only that each "enter" record exists. This task adds the id checks.

Blocker: FoundationModelsExtras OTel E ^wts388b (01M3MV1R3D52RAMFNFKWTS388B). With it, `TelemetryCapture` binds by default a tracer that records spans and injects and extracts `traceparent` and `tracestate`. A task cannot depend on a task on a different board, so this link is text only. Do not start this task until OTel E is on Extras origin/main.

- [ ] Update FoundationModelsExtras in `Package.resolved` to a revision that has OTel E.
- [ ] In `Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift` (OTel 6): assert that the "enter" record of the prompt, of `session/new` and of `session/resume` has the trace id and the span id of its span.
- [ ] In `Tests/FoundationModelsACPAgentTests/AgentSpanTests.swift` (OTel 8): assert the same for the elicitation span and the MCP connect span.
- [ ] Change no production code, unless a test shows that an id is wrong. In that case, fix the code that opens the span.

## Acceptance Criteria
- [ ] Each "enter" record that OTel 6 and OTel 8 write has a trace id and a span id equal to the ids of its span.
- [ ] The new assertions fail when the ids are removed from the record (check this one time in the red step of `/tdd`).

## Tests
- [ ] Run `swift test --filter "RequestTracingTests|AgentSpanTests"`. Expected: pass.
- [ ] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
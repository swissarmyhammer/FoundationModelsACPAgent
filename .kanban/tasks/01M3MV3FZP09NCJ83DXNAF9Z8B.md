---
depends_on:
- 01M3MNF3HX2STG00W3GBT21BAS
- 01M3MNF9A7FRPJJ3JZA503GB5G
position_column: todo
position_ordinal: '9680'
title: 'OTel 6b: add the enter record id checks of OTel 6 and OTel 8'
---
## What
OTel 6 (^bt21bas) and OTel 8 (^503gb5g) write an "enter" log record when a long call starts (design item 8), through `TracedCall.run` of FoundationModelsExtras. `TracedCall.run` reads the trace id and span id of that record from the W3C `traceparent` that the tracer injects. When OTel 6 and OTel 8 were planned, the `TelemetryCapture` tracer did not inject W3C `traceparent`, so those tasks check only that each "enter" record exists. This task adds the id checks.

FoundationModelsExtras OTel E ^wts388b is on Extras origin/main (6c399a4, 2026-09-28). Run `swift package update FoundationModelsExtras` first. `TelemetryCapture.Context.tracer` is now a `W3CInMemoryTracer`: it records spans and injects and extracts `traceparent` and `tracestate`, and the "enter" records of `TracedCall.run` have `trace.id` and `span.id`. Code that needs the `InMemoryTracer` type uses `context.tracer.inMemoryTracer`.

- [ ] Update FoundationModelsExtras in `Package.resolved` to 6c399a4 or later.
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
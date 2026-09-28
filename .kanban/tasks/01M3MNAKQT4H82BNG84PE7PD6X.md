---
assignees:
- claude-code
position_column: todo
position_ordinal: 8b80
title: 'OTel 1: add the ACPAgentTelemetry vocabulary file and the telemetry API products'
---
## What
Make the one vocabulary file of this package, the same shape as `FoundationModelsRouter/Sources/FoundationModelsRouter/Tracing/RouterTracing.swift`. The other OTel tasks on this board use it. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md` (items 1, 3, 4).

- [ ] In `Package.swift`, add the API-only products to the library target `FoundationModelsACPAgent`: `Tracing` (`swift-distributed-tracing`), `Logging` (`swift-log`), `Metrics` (`swift-metrics`). Declare the packages with the same version floors that FoundationModelsRouter and FoundationModelsExtras use (Extras card ^65xmgkv, 01M3MN838VZ4QX57C3965XMGKV, adds swift-log and swift-metrics there). `swift-distributed-tracing` and `swift-log` are already in `Package.resolved` through Router. Do NOT add `swift-otel` to the library target.
- [ ] Do not add telemetry test products here. OTel 3 adds the FoundationModelsExtras `TelemetryTestSupport` product to the test target, and the later OTel tests use its `TelemetryCapture`.
- [ ] Create `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift` with `enum ACPAgentTelemetry` and these nested enums:
  - `SpanName` — prefix `FoundationModelsACPAgent.`: `initialize`, `sessionNew`, `sessionResume`, `prompt`, `cancel`, `command`, `elicitation`, `mcpConnect`.
  - `AttributeKey` — `acp.method`, `session.id`, `prompt.stop_reason`, `command.name`, `command.kind`, `elicitation.mode`, `elicitation.outcome`, `mcp.server.name`, `mcp.server.transport`, `error.type`.
  - `MetricName` — prefix `foundation_models_acp_agent.`: `prompts`, `prompt_duration`, `active_sessions`, `commands`, `mcp_connect_failures`.
  - `MetricDimension` — `stop_reason`, `command.kind`, `outcome`, `transport`.
  - `LogMetadataKey` — the identifier keys that log metadata uses (`session.id`, `acp.method`, `command.name`, `mcp.server.name`, `elicitation.mode`).
  - `static func tracer(explicit: (any Tracer)?) -> any Tracer`, the resolve-late rule of `RouterTracing.tracer(explicit:)`.
- [ ] Write the "No content" rule in the doc comment, as `RouterTracing` does: no prompt text, response text, tool arguments, tool output or file content in a span attribute, a log message, a log metadata value or a metric dimension. Identifiers, names, counts and sizes are safe.

## Acceptance Criteria
- [ ] `swift build` compiles the library with `import Tracing`, `import Logging` and `import Metrics` available, and the library target has no `swift-otel` dependency.
- [ ] Each span name starts with `FoundationModelsACPAgent.` and each metric name starts with `foundation_models_acp_agent.`.
- [ ] No span name or metric name is written two times: a test reads all the names and finds no duplicate.

## Tests
- [ ] Add `Tests/FoundationModelsACPAgentTests/ACPAgentTelemetryTests.swift`: one case checks the span-name prefix, one checks the metric-name prefix, one checks that the names are unique.
- [ ] Run `swift test --filter ACPAgentTelemetryTests`. Expected: all cases pass.
- [ ] Run `swift build`. Expected: no error and no new warning.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
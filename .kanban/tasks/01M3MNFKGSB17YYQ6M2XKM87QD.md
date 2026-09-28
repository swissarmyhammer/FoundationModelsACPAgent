---
depends_on:
- 01M3MNC26MHCGN4R7BVKFQVQQB
- 01M3MNF2Y6B98SQ03420B65G02
- 01M3MNF37E55WV9B2778MDD7KZ
- 01M3MNF3HX2STG00W3GBT21BAS
- 01M3MNF9A7FRPJJ3JZA503GB5G
- 01M3MNF9KBQQ13EQQPFBFCX8KF
position_column: todo
position_ordinal: '9480'
title: 'OTel 10: content-safety test for all spans, logs and metrics of the agent'
---
## What
Design items 4 and 5: prove the no-content rule for all telemetry of this package — span attributes, log messages, log metadata and metric dimensions. Use the shared content-safety helper of FoundationModelsExtras: the `TelemetryTestSupport` product (Extras card ^z6jqd9g, 01M3MN8N9P4RPET2V5JZ6JQD9G). This task waits for OTel 3 to OTel 9 on this board. FoundationModelsExtras OTel A to D are on Extras origin/main (HEAD 70ad74d); run `swift package update FoundationModelsExtras` before you start. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md`.

The model is `FoundationModelsRouter/Sources/FoundationModelsRouter/Tracing/RouterTracing.swift` and its `SpanContentSafetyTests`: drive real work with fixture content, read every recorded value, and fail when a value carries a piece of that content.

- [ ] OTel 3 already adds `TelemetryTestSupport` to the test target. Use its `TelemetryCapture` with the test rules in OTel 3 (no `LoggingSystem.bootstrap`, `InstrumentationSystem.bootstrap` or `MetricsSystem.bootstrap`; make the agent inside the capture).
- [ ] Include the Extras tool-call span `FoundationModelsExtras.tool` (names in `ExtrasTelemetry.swift`): the tool-argument and tool-output fixtures must not appear on it.
- [ ] Add `Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift`. Use one set of unique fixture strings for: the prompt text, the command arguments, the model response (through `ScriptedModel`), a tool argument and a tool output, an elicitation answer, an MCP server `env` value and `headers` value, and a file content read by `InstructionsAssembler`.
- [ ] Drive, with the recorders of the helper: initialize, session/new with one config MCP server, one prompt with a tool call, one slash command with arguments, one elicitation round trip, session/cancel and session/close.
- [ ] Give all recorded spans, log records and metrics to the helper, and assert that no recorded value contains a fixture string.
- [ ] Update the doc comment of `ACPAgentTelemetry` (OTel 1) to name this test as the proof of the rule, as `RouterTracing` does.

## Acceptance Criteria
- [ ] The test drives each path that OTel 3 to OTel 9 instrumented, and each of those paths records at least one span, log record or metric (the test asserts this, so an empty recorder cannot pass).
- [ ] No recorded span attribute, log message, log metadata value or metric dimension contains a fixture string.
- [ ] If a later change puts the prompt text in a span attribute, this test fails (check this one time in the red step of `/tdd`).

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift` as above.
- [ ] Run `swift test --filter TelemetryContentSafetyTests`. Expected: pass.
- [ ] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
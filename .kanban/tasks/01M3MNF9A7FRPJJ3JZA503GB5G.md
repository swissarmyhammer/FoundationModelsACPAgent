---
depends_on:
- 01M3MNF3HX2STG00W3GBT21BAS
- 01M3MNF2Y6B98SQ03420B65G02
position_column: todo
position_ordinal: '9280'
title: 'OTel 8: spans for slash commands, the elicitation relay and the MCP server connect'
---
## What
Add spans to three agent paths that the Router spans do not cover: slash-command dispatch, the elicitation relay, and the MCP server connect. Each span is a child of the request span of OTel 6. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md` (items 3, 4, 8).

Use `TracedCall.run`, the span-plus-"enter"-log helper of FoundationModelsExtras (Extras card ^ykgz2aa, 01M3MN91YK71YVJ9C7WYKGZ2AA), for each span below that can suspend for a long time. The tool-call span inside a prompt is already opened by Extras with the name `FoundationModelsExtras.tool` (names in `ExtrasTelemetry.swift`); do not open a second one here.

Extras: FoundationModelsExtras OTel A to D are on Extras origin/main (HEAD 70ad74d, 2026-09-28). Run `swift package update FoundationModelsExtras` before you start this task.

- [ ] Slash commands — `dispatchCommand(_:params:...)` in `Sources/FoundationModelsACPAgent/Commands/CommandDispatch.swift`: span `ACPAgentTelemetry.SpanName.command` with `command.name` and `command.kind` (builtin, skill, prompt template, action). Never the arguments text or the expanded template. Record a refusal (`unknownCommand`, `actionCommandAttachments`, `commandExpansionFailed`) as the span error with `error.type`.
- [ ] Elicitation relay — `relay(_:on:...)` in `Sources/FoundationModelsACPAgent/Agent/ElicitationRelay.swift`: span `SpanName.elicitation` with `elicitation.mode` and `elicitation.outcome` (accept, decline, cancel). This span waits for the user, so it writes the "enter" log. Never the schema text, the message or the answer content.
- [ ] MCP connect — `connect(entry:spawnedProcesses:)` in `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift`: one span `SpanName.mcpConnect` for each server, with `mcp.server.name` and `mcp.server.transport` (stdio or http). It can wait for a slow server, so it writes the "enter" log. Never the command arguments, `env` values, `headers` values or the URL query.

## Acceptance Criteria
- [ ] A `/help` prompt through the harness records one `FoundationModelsACPAgent.command` span that is a child of the prompt span, with `command.name = help`.
- [ ] An unknown command records the span with an error and `error.type`.
- [ ] One elicitation round trip records one `FoundationModelsACPAgent.elicitation` span with the mode and the outcome, and one "enter" log record before the answer comes.
- [ ] `session/new` with one config MCP server (the `mcp-test-server` product) records one `FoundationModelsACPAgent.mcpConnect` span that is a child of the `session/new` span; a server that fails to connect records the error.

## Tests
- [ ] Add `Tests/FoundationModelsACPAgentTests/AgentSpanTests.swift` with one case for each acceptance criterion. Use `TelemetryCapture` the same way as `RequestTracingTests` (OTel 6), with the test rules in OTel 3, the fixtures of `CommandDispatchTests.swift`, `ElicitationRelayTests.swift` and `MCPCompositionTests.swift`, and `BuiltProductLocator` for `mcp-test-server`.
- [ ] In this task, assert only that the "enter" record exists. Task OTel 6b ^naf9z8b adds the id checks. (Extras OTel E ^wts388b is on origin/main: `TelemetryCapture.Context.tracer` is a `W3CInMemoryTracer`; code that needs the `InMemoryTracer` type uses `context.tracer.inMemoryTracer`.)
- [ ] Run `swift test --filter AgentSpanTests`. Expected: pass.
- [ ] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
---
comments:
- actor: claude-code
  id: 01m3qsaedwesh0pnnc55s2f2n9
  text: |-
    Research done.
    - Extras is at origin/main already (Package.resolved revision 3de1179 = remote main). `swift package update` is not necessary.
    - The design file of the card (otel-design.md in an old scratchpad) does not exist any more. The card text is the specification.
    - `TracedCall.run` is `async throws`, not `rethrows`. `ElicitationRelay.relay` does not throw, so the relay span needs `try?` on a body that cannot throw.
    - `CommandRegistry` does not record the source of a command. To give `command.kind` (builtin, skill, prompt template, action), the registry must record the kind of each merged command.
    - The existing test `aDeclineForAnUnsupportedModeWritesOneNoticeWithTheModeInMetadata` counts the records that have `elicitation.mode = url` in their metadata. Thus the "enter" record of the elicitation span must not carry the mode in its metadata (the span attribute carries it).
    - The relay runs in the deferred prompt work. The capture task-locals reach that work (the existing decline log test proves it), so `InstrumentationSystem.tracer` gives the capture tracer there.
    - `connectServers` runs inside the `session/new` span context (ToolCatalog, no detached task), so the MCP connect span is a child of the `session/new` span.
  timestamp: 2026-09-29T23:52:09.404782+00:00
- actor: claude-code
  id: 01m3qsv05v8qkfsjxw5kwhm5my
  text: |-
    Implementation landed.
    - New `Telemetry/AgentTracing.swift`: `withSpan` (internal span, rethrows) and `withEnteredSpan` (over `TracedCall.run`, writes the "enter" record). Both put `error.type` on the span of a body that throws. The `recordingErrorType` and `recordErrorType` helpers moved here from `RequestTracing`, so the request spans and the agent spans use one copy.
    - Slash commands: `dispatchCommand` opens `SpanName.command` with `command.name`, and `command.kind` for a registered command. The span covers the lookup, the refusals, the expansion and the render only. The work after the `{}` response is scheduled after the span ends, in the prompt span context, so the Router submission spans of a command prompt stay children of the prompt span (the documented rule of `scheduleModelPrompt`). A new private `CommandWork` enum carries the resolved work out of the span.
    - `CommandRegistry` records a `CommandKind` (`builtin`, `skill`, `prompt_template`, `action`) for each merged command, and gives it through `kind(ofCommandNamed:)`. A linked-provider `.rendered` body is `prompt_template`, because its text goes to the model as a prompt.
    - Elicitation relay: one `SpanName.elicitation` span for each request, with the mode and the outcome (the action of the answer that went to Router; a decline of the relay itself is `decline`). The "enter" record carries the session id and the elicitation id only. It does not carry the mode, because `aDeclineForAnUnsupportedModeWritesOneNoticeWithTheModeInMetadata` counts the records that carry `elicitation.mode`. `TracedCall.run` is not `rethrows`, so the relay uses `try?` over a body that does not throw.
    - MCP connect: `connect(entry:spawnedProcesses:)` opens `SpanName.mcpConnect` with the server name and the transport (`stdio` or `http`), and writes the "enter" record with the server name. The old body is now `connectToReady`.
    - The `periphery:ignore` markers of `elicitationOutcome` and `mcpServerTransport` are removed. The `MetricDimension` marker stays for OTel 9.
    - Tests: `AgentSpanTests.swift` (5 cases; the MCP criterion has one case for the connect and one for the failure). `TracedRun` moved from `RequestTracingTests` to `Support/TracedRun.swift`, so both suites use it. `CommandRegistryTests.eachMergedCommandHasTheKindOfItsSource` covers each `CommandKind`; it was written after the implementation, not first.
    - Not done here: the enter record id checks (OTel 6b).
  timestamp: 2026-09-30T00:01:11.867842+00:00
- actor: claude-code
  id: 01m3qsv5ktg574y4cb4977cc8g
  text: |-
    ### implement — changed
    - evidence: `swift test --filter AgentSpanTests` failed first (5 of 5, no span), then passed 5 of 5. `swift test`: 661 tests in 74 suites passed (1 known issue, the existing `withKnownIssue` in HarnessSmokeTests). `swift build --build-tests` in IntegrationTests/: Build complete. Zero compiler warnings (only the existing build-system note "missing creator for mutated node").
    - files: Sources/FoundationModelsACPAgent/Telemetry/AgentTracing.swift (new), Telemetry/RequestTracing.swift, Telemetry/ACPAgentTelemetry.swift, Commands/CommandDispatch.swift, Commands/CommandRegistry.swift, Agent/ElicitationRelay.swift, Tools/MCPComposition.swift, Tests/FoundationModelsACPAgentTests/AgentSpanTests.swift (new), Tests/FoundationModelsACPAgentTests/Support/TracedRun.swift (new), Tests/FoundationModelsACPAgentTests/RequestTracingTests.swift, Tests/FoundationModelsACPAgentTests/CommandRegistryTests.swift
    - next: /review
  timestamp: 2026-09-30T00:01:17.434225+00:00
depends_on:
- 01M3MNF3HX2STG00W3GBT21BAS
- 01M3MNF2Y6B98SQ03420B65G02
position_column: doing
position_ordinal: '80'
title: 'OTel 8: spans for slash commands, the elicitation relay and the MCP server connect'
---
## What
Add spans to three agent paths that the Router spans do not cover: slash-command dispatch, the elicitation relay, and the MCP server connect. Each span is a child of the request span of OTel 6. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md` (items 3, 4, 8).

Use `TracedCall.run`, the span-plus-"enter"-log helper of FoundationModelsExtras (Extras card ^ykgz2aa, 01M3MN91YK71YVJ9C7WYKGZ2AA), for each span below that can suspend for a long time. The tool-call span inside a prompt is already opened by Extras with the name `FoundationModelsExtras.tool` (names in `ExtrasTelemetry.swift`); do not open a second one here.

Extras: FoundationModelsExtras OTel A to D are on Extras origin/main (HEAD 70ad74d, 2026-09-28). Run `swift package update FoundationModelsExtras` before you start this task.

- [x] Slash commands — `dispatchCommand(_:params:...)` in `Sources/FoundationModelsACPAgent/Commands/CommandDispatch.swift`: span `ACPAgentTelemetry.SpanName.command` with `command.name` and `command.kind` (builtin, skill, prompt template, action). Never the arguments text or the expanded template. Record a refusal (`unknownCommand`, `actionCommandAttachments`, `commandExpansionFailed`) as the span error with `error.type`.
- [x] Elicitation relay — `relay(_:on:...)` in `Sources/FoundationModelsACPAgent/Agent/ElicitationRelay.swift`: span `SpanName.elicitation` with `elicitation.mode` and `elicitation.outcome` (accept, decline, cancel). This span waits for the user, so it writes the "enter" log. Never the schema text, the message or the answer content.
- [x] MCP connect — `connect(entry:spawnedProcesses:)` in `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift`: one span `SpanName.mcpConnect` for each server, with `mcp.server.name` and `mcp.server.transport` (stdio or http). It can wait for a slow server, so it writes the "enter" log. Never the command arguments, `env` values, `headers` values or the URL query.

## Acceptance Criteria
- [x] A `/help` prompt through the harness records one `FoundationModelsACPAgent.command` span that is a child of the prompt span, with `command.name = help`.
- [x] An unknown command records the span with an error and `error.type`.
- [x] One elicitation round trip records one `FoundationModelsACPAgent.elicitation` span with the mode and the outcome, and one "enter" log record before the answer comes.
- [x] `session/new` with one config MCP server (the `mcp-test-server` product) records one `FoundationModelsACPAgent.mcpConnect` span that is a child of the `session/new` span; a server that fails to connect records the error.

## Tests
- [x] Add `Tests/FoundationModelsACPAgentTests/AgentSpanTests.swift` with one case for each acceptance criterion. Use `TelemetryCapture` the same way as `RequestTracingTests` (OTel 6), with the test rules in OTel 3, the fixtures of `CommandDispatchTests.swift`, `ElicitationRelayTests.swift` and `MCPCompositionTests.swift`, and `BuiltProductLocator` for `mcp-test-server`.
- [x] In this task, assert only that the "enter" record exists. Task OTel 6b ^naf9z8b adds the id checks. (Extras OTel E ^wts388b is on origin/main: `TelemetryCapture.Context.tracer` is a `W3CInMemoryTracer`; code that needs the `InMemoryTracer` type uses `context.tracer.inMemoryTracer`.)
- [x] Run `swift test --filter AgentSpanTests`. Expected: pass.
- [x] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
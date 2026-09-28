---
depends_on:
- 01M3MNAKQT4H82BNG84PE7PD6X
- 01M3MNC26MHCGN4R7BVKFQVQQB
position_column: todo
position_ordinal: '9380'
title: 'OTel 9: metrics for prompts, active sessions, commands and MCP connect failures'
---
## What
Add the agent metrics through the `swift-metrics` API (design item 1). The library uses only the API; `acp-agent` exports them through `swift-otel` (OTel 2). Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md` (items 1, 3, 4).

Extras: FoundationModelsExtras OTel A to D are on Extras origin/main (HEAD 70ad74d, 2026-09-28). Run `swift package update FoundationModelsExtras` before you start this task. OTel 3 must also be done first, because it adds `TelemetryTestSupport` to the test target.

A metric object made before a `TelemetryCapture` starts does not go to the capture. So do not keep a `Counter`, `Timer` or `Gauge` in a global or `static let`. Make it at the call, or on the instance in its `init`.

Names come from `ACPAgentTelemetry.MetricName` (OTel 1). Dimensions are low-cardinality names only. A session id is NOT a dimension (it has no bound), and content is never a dimension (design item 4).

- [ ] Prompt count and duration — `prompt(_:)` in `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift`: a `Counter` `prompts` and a `Timer` `prompt_duration`, both with the dimension `stop_reason` (the ACP `StopReason` raw value, or `error`).
- [ ] Active sessions — `sessions` in `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift`: a `Gauge` `active_sessions`. Record the count each time a session is added (session/new, session/resume) or removed (session/close, session/delete; see `Agent/SessionLifecycle.swift`).
- [ ] Command count — `dispatchCommand` in `Sources/FoundationModelsACPAgent/Commands/CommandDispatch.swift`: a `Counter` `commands` with the dimensions `command.kind` and `outcome` (ok or refused). Not the command name of a user-defined command: the set of names has no bound.
- [ ] MCP connect failures — `connect(entry:spawnedProcesses:)` in `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift`: a `Counter` `mcp_connect_failures` with the dimension `transport` (stdio or http).

## Acceptance Criteria
- [ ] One prompt that ends with `end_turn` adds 1 to `prompts{stop_reason=end_turn}` and records one `prompt_duration` value.
- [ ] After two `session/new` and one `session/close`, the last `active_sessions` value is 1.
- [ ] A `/help` prompt adds 1 to `commands{command.kind=builtin,outcome=ok}`.
- [ ] A config MCP server that cannot start adds 1 to `mcp_connect_failures{transport=stdio}`.
- [ ] No metric has a session id, a prompt text or a command argument in a dimension.

## Tests
- [ ] Add `Tests/FoundationModelsACPAgentTests/AgentMetricsTests.swift`. Use `TelemetryCapture` from Extras `TelemetryTestSupport` (its task-local `withMetricsFactory`; never `MetricsSystem.bootstrap`), with the test rules in OTel 3. Make the agent inside the capture, and read the values of each case by name and dimensions. Drive the cases through the harness in `Tests/FoundationModelsACPAgentTestSupport/Harness.swift` and the fixtures of `MCPCompositionTests.swift`.
- [ ] Run `swift test --filter AgentMetricsTests`. Expected: pass.
- [ ] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
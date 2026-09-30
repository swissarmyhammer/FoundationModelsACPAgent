---
comments:
- actor: claude-code
  id: 01m3qvjkqyth3rppp3pjv3jtjj
  text: |-
    Research done. Discoveries:
    - The card names `Agent/PromptTurn.swift`. That file is now `Agent/PromptExecution.swift`. `prompt(_:)` is there.
    - The pinned Extras `TelemetryCapture` binds its `TestMetrics` factory with the task-local `withMetricsFactory`. No global bootstrap is necessary. Extras own tests link the `MetricsTestKit` product of swift-metrics to read the values (`expectCounter`, `expectTimer`, `expectGauge`). This package adds the same product to its unit test target.
    - The work of a prompt after the `{}` response runs through `afterRespondingToCurrentRequest`. The task-local values of the handler do not reach that work (RequestTracing says this for `ServiceContext`). Thus the prompt metrics read `MetricsSystem.factory` in the handler, and make the counter and the timer with that factory when the stop reason is known.
    - `session/close` does not remove the table entry. It marks the entry closed, so that the session stays resumable. Thus `active_sessions` counts the entries that are not closed. The value is recorded where a session is activated (new and resume), marked closed, removed by delete, or replaced by resume.
    - An unknown command has no `CommandKind`. The `command.kind` dimension of its refusal uses the fixed value `unknown`.
  timestamp: 2026-09-30T00:31:34.142187+00:00
- actor: claude-code
  id: 01m3qw4qghcjnqhcnfkrmsmeze
  text: |-
    Implementation landed (TDD: the five new cases failed with `missingMetric` first, then passed).
    - New `Telemetry/AgentMetrics.swift`: `AgentMetrics` (commands counter, MCP connect failure counter, active sessions gauge) and `PromptMeasurement`. Each metric is made at the call, never kept in a `static let`.
    - `PromptMeasurement` reads `MetricsSystem.factory` and the start time in the `session/prompt` handler, and records `prompts` and `prompt_duration` when the stop reason is known, in the work after the `{}` response. A refused prompt records `stop_reason=error`. Reason: the connection runs the work after the response outside the task of the handler, so a task-local factory does not reach it.
    - `RoutedACPAgent.recordActiveSessions()` counts the entries that are not closed. It runs after `activateSession` (new and resume), `markSessionClosed` (close and delete), the delete removal and the resume replacement.
    - `dispatchCommand` records `commands{command.kind, outcome}` with `ok` or `refused`. An unknown name gives `command.kind=unknown`; the name is never a dimension.
    - `MCPComposition.connect` records `mcp_connect_failures{transport}` when the connect throws.
    - Removed the `// periphery:ignore` marker and its note from `MetricDimension`; all four keys have readers now.
    - `Package.swift`: the unit test target links `MetricsTestKit` of swift-metrics (the same product that Extras tests link) to read the `TestMetrics` values.
    - Test note: a script of `[.endPass]` alone ends with `_no_output`, not `end_turn`. The prompt case uses `[.textDelta(answer), .endPass]`.
  timestamp: 2026-09-30T00:41:27.825702+00:00
- actor: claude-code
  id: 01m3qw4tsq5408mcmfpj9g1r51
  text: |-
    ### implement — changed
    - evidence: `swift test --filter AgentMetricsTests` 5/5 pass; `swift test` 666 tests in 75 suites pass (1 known issue is the existing deliberate one in HarnessSmokeTests); no compiler warnings (the only build line is the existing SwiftPM "missing creator for mutated node" note on the mlx-swift_Cmlx bundle); `swift build --build-tests` in IntegrationTests/ completes. Files: Package.swift, Sources/FoundationModelsACPAgent/Telemetry/AgentMetrics.swift (new), Telemetry/ACPAgentTelemetry.swift, RoutedACPAgent.swift, Agent/PromptExecution.swift, Agent/SessionSetup.swift, Agent/SessionLifecycle.swift, Agent/SessionResume.swift, Commands/CommandDispatch.swift, Tools/MCPComposition.swift, Tests/FoundationModelsACPAgentTests/AgentMetricsTests.swift (new).
    - next: /review
  timestamp: 2026-09-30T00:41:31.191105+00:00
- actor: claude-code
  id: 01m3qwp2mvs81fvmwhe0w166dv
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit e9ebcab). 11 files reviewed. Findings 0, confirmed 0, refuted 2, attempted 7, failed 0. The task had no prior review findings.
    - next: The task is in done. No work remains.
  timestamp: 2026-09-30T00:50:56.283574+00:00
- actor: claude-code
  id: 01m3qwpa6p6s469gt1v97ct24h
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 11 files (2 new)
    - test: green — swift test 666 tests pass; IntegrationTests build ok
    - commit: e9ebcab
    - review: clean — zero findings; task moved to done
  timestamp: 2026-09-30T00:51:04.022594+00:00
depends_on:
- 01M3MNAKQT4H82BNG84PE7PD6X
- 01M3MNC26MHCGN4R7BVKFQVQQB
position_column: done
position_ordinal: ff8580
title: 'OTel 9: metrics for prompts, active sessions, commands and MCP connect failures'
---
## What
Add the agent metrics through the `swift-metrics` API (design item 1). The library uses only the API; `acp-agent` exports them through `swift-otel` (OTel 2). Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md` (items 1, 3, 4).

Extras: FoundationModelsExtras OTel A to D are on Extras origin/main (HEAD 70ad74d, 2026-09-28). Run `swift package update FoundationModelsExtras` before you start this task. OTel 3 must also be done first, because it adds `TelemetryTestSupport` to the test target.

A metric object made before a `TelemetryCapture` starts does not go to the capture. So do not keep a `Counter`, `Timer` or `Gauge` in a global or `static let`. Make it at the call, or on the instance in its `init`.

Names come from `ACPAgentTelemetry.MetricName` (OTel 1). Dimensions are low-cardinality names only. A session id is NOT a dimension (it has no bound), and content is never a dimension (design item 4).

- [x] Prompt count and duration — `prompt(_:)` in `Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift` (the card named `PromptTurn.swift`; the file has a new name): a `Counter` `prompts` and a `Timer` `prompt_duration`, both with the dimension `stop_reason` (the ACP `StopReason` raw value, or `error`).
- [x] Active sessions — `sessions` in `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift`: a `Gauge` `active_sessions`. Record the count each time a session is added (session/new, session/resume) or removed (session/close, session/delete; see `Agent/SessionLifecycle.swift`).
- [x] Command count — `dispatchCommand` in `Sources/FoundationModelsACPAgent/Commands/CommandDispatch.swift`: a `Counter` `commands` with the dimensions `command.kind` and `outcome` (ok or refused). Not the command name of a user-defined command: the set of names has no bound.
- [x] MCP connect failures — `connect(entry:spawnedProcesses:)` in `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift`: a `Counter` `mcp_connect_failures` with the dimension `transport` (stdio or http).

## Acceptance Criteria
- [x] One prompt that ends with `end_turn` adds 1 to `prompts{stop_reason=end_turn}` and records one `prompt_duration` value.
- [x] After two `session/new` and one `session/close`, the last `active_sessions` value is 1.
- [x] A `/help` prompt adds 1 to `commands{command.kind=builtin,outcome=ok}`.
- [x] A config MCP server that cannot start adds 1 to `mcp_connect_failures{transport=stdio}`.
- [x] No metric has a session id, a prompt text or a command argument in a dimension.

## Tests
- [x] Add `Tests/FoundationModelsACPAgentTests/AgentMetricsTests.swift`. Use `TelemetryCapture` from Extras `TelemetryTestSupport` (its task-local `withMetricsFactory`; never `MetricsSystem.bootstrap`), with the test rules in OTel 3. Make the agent inside the capture, and read the values of each case by name and dimensions. Drive the cases through the harness in `Tests/FoundationModelsACPAgentTestSupport/Harness.swift` and the fixtures of `MCPCompositionTests.swift`.
- [x] Run `swift test --filter AgentMetricsTests`. Expected: pass.
- [x] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel
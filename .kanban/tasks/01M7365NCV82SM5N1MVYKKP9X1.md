---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73fa2xyznntmdqeq8nztk1q
  text: |-
    Decision (from the dispatch order of this step): the `initialize` result of a `sandboxed` agent omits `mcp.stdio`, because no stdio server can start in that mode (`MCPComposition.Refusal.stdioInSandboxedMode`). It advertises `mcp.http` only. An `open` agent advertises both, as before.

    Research: `RoutedACPAgent.advertisedCapabilities` was a `static let`. `negotiate(_:from:)` in Initialization.swift is its only production reader. Tests read it in InitializationTests and PromptContentTests. `ToolMode` (FoundationModelsExtras) is a closed enum with `open` and `sandboxed`. `MCPCapabilities.stdio` is optional. Plan: replace the static property with `static func advertisedCapabilities(in mode: ToolMode)`, and `negotiate` gives it `toolMode`.
  timestamp: 2026-11-10T19:35:10.526286+00:00
- actor: claude-code
  id: 01m73h4b2775fe6nqjc53635m9
  text: |-
    ### implement — changed
    - evidence: branch `par/kkp9x1`, commit fdc91ef, in worktree .claude/worktrees/agent-ac0d9adfddff7e50e. 3 files: Sources/FoundationModelsACPAgent/Agent/Initialization.swift (the static `advertisedCapabilities` became `static func advertisedCapabilities(in: ToolMode)` and `advertisedMCPCapabilities(in:)`; `negotiate` gives it `toolMode`), Tests/FoundationModelsACPAgentTests/InitializationTests.swift (new `initializeAdvertisesTheMCPTransportsOfTheToolMode`, one case for each `ToolMode`: open gives stdio and http, sandboxed gives http only), Tests/FoundationModelsACPAgentTests/PromptContentTests.swift (the prompt test now runs for each mode).
    - RED: the sandboxed case failed (stdio was advertised). GREEN: 3 tests in 2 suites passed.
    - full `swift test`: 1919 tests in 211 suites. The machine load average was 60 to 143 from parallel agents. Three full runs failed only from timing: 60 s and 120 s time limits, and late updates (AgentsToolTests, HookCompositionTests, GraphQLTunnelTests, BackgroundListTests, ScriptedElicitStepTests, ElicitationRelayTests, SubagentSessionsReplayTests, HotResumeTests, SubagentMessageWireTests). The failed set changed in each run. Each of these suites passed when it ran alone: 100/100, 86/86, 11/11. The last full run (`--no-parallel`) had 2 issues, in SubagentMessageWireTests, and that suite passes alone. No compiler warning from project code. The only `warning:` line is the SwiftPM note `missing creator for mutated node` on the mlx bundle.
    - next: run the full suite again when the machine is not loaded, then review.
  timestamp: 2026-11-10T20:06:59.399130+00:00
position_column: todo
position_ordinal: '8980'
title: The initialize capabilities advertise mcp.stdio in sandboxed mode
---
## What
`RoutedACPAgent.advertisedCapabilities` (Sources/FoundationModelsACPAgent/Agent/Initialization.swift) is static. It always advertises `session.mcp.stdio`. After ^xfeamnv, an agent in `sandboxed` tool mode refuses each stdio MCP server (`MCPComposition.Refusal.stdioInSandboxedMode`). A client can thus send a stdio server that the agent always refuses.

Decide with testudoapp-75 if the `initialize` result of a `sandboxed` agent must omit `mcp.stdio`. If yes, make the capabilities read `toolMode`.

## Acceptance Criteria
- [ ] The decision is recorded on this task.
- [ ] If the decision is to omit it: a `sandboxed` agent advertises `mcp.http` only, and an `open` agent advertises both.

## Tests
- [ ] InitializationTests: the `mcp` capability for each `ToolMode`. #step1
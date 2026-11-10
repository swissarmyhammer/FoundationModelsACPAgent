---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73ppmezfmpgthsyx57vhdf4
  text: |-
    Research (implement):
    - `SkillsRegistry` (FoundationModelsSkills, pinned) takes `templateContext` only at init. It has no setter. A skill description renders at load. Thus the values cannot change after the registry is made. The registry must be made after the session agent is known.
    - `composeSession` (SessionSetup.swift) makes the skills source first, then `sessionSurface`, then `composeSessionAgent(runner:)`, then `applying(agent:)`. The session agent is resolved from `runner.catalog()`, thus after the skills registry. The runner needs the environment, and the environment needs the skills registry. That is a cycle.
    - The agent registry needs only the catalog context and the marketplace store. It does not need the skills registry. Thus the correct order: start the marketplace store, make and load the agent registry, resolve the session agent from its catalog, make the skills registry with the selected values, then compose the surface over the same loaded agent registry.
    - Resolve one time only: `SessionAgentResolution.restore` logs a warning when the recorded agent is gone. Two resolutions give two warnings.
    - The group names of the template (`files`, `shell`, `web`, `git`, `environment`, `codeContext`, `kanban`) are the capability names that `SessionToolSelection` reads. `files` and `kanban` are in `ToolCatalog.alwaysOnToolNames`, thus they stay. MCP tools are `mcp__<server>__<tool>`; the template value `mcp` follows a probe name for each configured server.
    - The skills registry is shared with the agent runs (one `AgentEnvironment`). After this change the runs also see the values of the root session agent. The pinned packages give no per-run context.
    - The body of the session agent renders through the agent registry (`AgentBodyRenderer` reads `registry.templateContext`). The agent registry is needed to resolve the agent, thus its values cannot follow the selection with one registry. The `skills:` preload renders through the skills registry, thus it follows.
  timestamp: 2026-11-10T21:44:21.727375+00:00
- actor: claude-code
  id: 01m73q254c2dy2tvc5dp854zvc
  text: |-
    Implementation landed (not committed):
    - `ToolCatalog.skillsTemplateContext(_:mode:sessionAgent:)` takes the session agent. `SessionToolSelection.templateGroups(_:of:mcpServerNames:)` applies the same selection as `applying(agent:)` to the group names. A key never turns a group on. Thus the sandboxed rule (shell and codeContext false) stays, and `files`, `kanban`, `skills` and `agents` stay. `mcp` reads one probe `mcp__<server>__` for each configured server, else the probe `mcp__`.
    - New order in `composeSession`: start the marketplace store (`ToolCatalog.startSkillsMarketplaces`), load the agent registry (`AgentsComposition.loadedAgentRegistry`), resolve the session agent one time (`resolveSessionAgent(in:...)`), make the skills source with the agent (`makeSkillsSource(context:marketplaces:sessionAgent:)`), then `sessionSurface(context:skills:agentRegistry:)` reuses the loaded registry. `composeSessionAgent(_:catalog:runner:)` only renders now. `SessionAgentPrompt.builtin` was dead after the change and is removed.
    - Gap filed as a new task ^vshf002: the body of the session agent renders through the agent registry, whose values are fixed before the agent is known. The agent runs share the one skills registry, thus a run sees the values of the root session agent.
    - RED seen: the unit tests did not compile with no `sessionAgent:` parameter; the composed-session test failed with `PROBE-SHELL-ON` in the instructions before the reorder.

    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Sources/FoundationModelsACPAgent/Tools/SessionAgentTools.swift, Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift, Sources/FoundationModelsACPAgent/Agent/SessionAgentComposition.swift, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift (9 new tests). `swift build --build-tests`: 0 warnings. `swift test`: 1971 tests in 215 suites passed, 0 failures (1 known issue: the existing `withKnownIssue` in HarnessSmokeTests).
    - next: /review
  timestamp: 2026-11-10T21:50:39.244215+00:00
position_column: doing
position_ordinal: '80'
title: The skills template values follow the tool selection of the session agent
---
## What
`ToolCatalog.skillsTemplateContext` gives each skill render the values `tools.<group>.enabled`. It reads only the configuration and the tool mode. Since ^b013mv9 (ACPA-1b), the `tools:` and `disallowedTools:` keys of the session agent can remove a capability from the root session (`SessionSurface.applying(agent:)`). The template values do not follow that selection. A skill then gives the steps of a tool, for example `{% if tools.shell.enabled %}`, that the session does not have.

The values are made in `ToolCatalog.makeSkillsSource(context:)` and `AgentsComposition.makeAgentRegistry`, before the session agent is known. The instructions of the session agent and its `skills:` preload are rendered in `composeSessionAgent`, also before the selection.

## Acceptance Criteria
- [ ] A session agent with `disallowedTools: [shell]` renders a skill with `tools.shell.enabled` as `false`.
- [ ] A session agent with no `tools:` key renders the same values as today.

## Tests
- [ ] A unit test for each criterion.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd`. #step1
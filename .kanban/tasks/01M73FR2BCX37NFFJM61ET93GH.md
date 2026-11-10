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
- actor: claude-code
  id: 01m73q7fass15f42s3dr3xpnh2
  text: |-
    ### review — findings
    - evidence: review sha fcd75f1~1..fcd75f1; 2 findings (2 confirmed, 3 refuted) — Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift:919, Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift:390
    - next: implement the 2 open items in "Review Findings (2026-11-10 15:51)"; the task stays in review.
  timestamp: 2026-11-10T21:53:33.529635+00:00
- actor: claude-code
  id: 01m73r9vk838stjc83tce2q5gm
  text: |-
    Findings pass (implement):
    - Research: I examined each template key against the surface. The Multitool nouns are `files`, `shell`, `web`, `git`, `environment` (the `noun` of each capability). `kanban` is an operation tool noun, and `skills` is a tool name. Only `codeContext` is different: its surface group is `code_context` (`ToolCatalog.codeContextGroupName`).
    - Fix: new `ToolCatalog.codeContextTemplateGroup` ("codeContext") and `ToolCatalog.templateGroupSurfaceNames` (template key to surface name). `SessionToolSelection.templateGroups` now gives the selection the surface name of each group (`surfaceName(ofTemplateGroup:)`), and reads the kept set by that name.
    - Test reuse: `templateValues(keys:mode:)` takes `keys: [String]?`; `nil` gives no session agent. `noToolsKeyKeepsTheTemplateValuesOfTheConfiguration` compares `templateValues(keys: [])` with `templateValues(keys: nil)`.
    - RED seen: `toolsCodeContextKeepsTheCodeContextTemplateValueOn` failed before the fix (value false), and passed after it.
    - Both findings are now `- [x]`.

    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Sources/FoundationModelsACPAgent/Tools/SessionAgentTools.swift, Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift (1 new test). `swift test`: 1973 tests in 215 suites passed, 0 failures, 0 compiler warnings (1 known issue: the existing `withKnownIssue` in HarnessSmokeTests; the SwiftPM line "missing creator for mutated node" for the mlx bundle is a build-graph message, not a compiler warning).
    - next: /review
  timestamp: 2026-11-10T22:12:20.200761+00:00
- actor: claude-code
  id: 01m73rd8pqmhx2xqs58yx26tgw
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (ec3f6ce). 1 finding (1 confirmed, 0 refuted). Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift:401. The 2 prior findings (ToolCatalog.swift:919, SessionAgentToolsTests.swift:390) are checked.
    - next: implement — add a test that `disallowedTools: [code_context]` renders `tools.codeContext.enabled` as false.
  timestamp: 2026-11-10T22:14:11.927110+00:00
- actor: claude-code
  id: 01m73rkj8q3aptxf0ee9tfhyxk
  text: |-
    Findings pass (implement), finding 2026-11-10 16:12:
    - I examined each template group for one-sided tests. `mcp` had the two directions (`tools: [web]` gives false, `"mcp__*"` gives true). Four groups had only one direction: `codeContext` (keep only), `web` (keep only), `shell` (remove only in the `open` mode; the keep test used the `sandboxed` mode), `files` (keep only). `git`, `environment`, `kanban` and `agents` have no template value test in either direction. I did not add tests for them, because the order is for groups with one direction tested.
    - New tests in SessionAgentToolsTests.swift: `disallowedCodeContextTurnsTheCodeContextTemplateValueOff` (the finding), `disallowedWebTurnsTheWebTemplateValueOff`, `toolsShellInTheOpenModeKeepsTheShellTemplateValueOn`, `disallowedFilesKeepsTheFilesTemplateValueOn` (files always stays, D90 (c)).
    - The tests cover behavior that exists, thus they passed on the first run. To prove that the code_context test can fail, I changed `surfaceName(ofTemplateGroup:)` to return the template key. The test then failed (1 issue). I reverted the change; `git diff` of SessionAgentTools.swift is empty.
    - The finding is now `- [x]`.

    ### implement — changed
    - evidence: Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift (4 new tests). `swift test`: 1977 tests in 215 suites passed, 0 failures, 0 compiler warnings (1 known issue: the existing `withKnownIssue` in HarnessSmokeTests; the SwiftPM line "missing creator for mutated node" for the mlx bundle is a build-graph message, not a compiler warning).
    - next: /review
  timestamp: 2026-11-10T22:17:38.327825+00:00
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

## Review Findings (2026-11-10 15:51)

> Scope: `review sha fcd75f1~1..fcd75f1` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift:919` `completeness/invariant-propagation` — The new `templateGroups` match compares each template group key against the tool names the agent selects. The `codeContext` key is matched as a tool name, but the Multitool group that the surface mounts is `code_context` (`ToolCatalog.codeContextGroupName`). An agent that keeps `tools: [code_context]` still gets `tools.codeContext.enabled` = false, so skills tell the model that code context is off while the tool is present. The same rule is not applied to the name the runtime surface uses. Match each template group against its surface name, not its template key. Either map `codeContext` to `ToolCatalog.codeContextGroupName` before calling `templateGroups`, or add a case in `templateGroups` for that key. Add one test that `tools: [code_context]` keeps `tools.codeContext.enabled` at its configured value.
- [x] `Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift:390` `reuse/reuse` — The test `noToolsKeyKeepsTheTemplateValuesOfTheConfiguration` writes out the baseline expression `enabledValues(of: ToolCatalog.skillsTemplateContext(AgentConfiguration.withoutMarketplaces.tools, mode: .open))` by hand. The helper `templateValues(keys:mode:)` already builds the same call from the same configuration, and differs only in the session agent it passes. The near-match was not extended, so the test carries its own copy of the call. Give the helper an optional agent, for example `templateValues(keys: [String]?, mode:)`, or add a `configuredValues(mode:)` helper that both the baseline and `templateValues` call. Then the no-key test compares the two helper results and does not repeat the call.

## Review Findings (2026-11-10 16:12)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift:401` `completeness/inverse-operation-coverage` — The new test covers only the keep direction of code_context. The remove direction, where disallowedTools: [code_context] renders codeContext as false, is not asserted, although the fix changes that path too. Add a test that renders the template values for keys: ["disallowedTools: [code_context]"] and asserts that the codeContext value is false.

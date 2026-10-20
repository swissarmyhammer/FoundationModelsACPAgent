---
assignees:
- claude-code
depends_on:
- 01M5CZ1Y88XJXTTF4XCZT60YV4
position_column: todo
position_ordinal: '8780'
title: 'ACPA-16: the agents come from the same list of folders (AG-10)'
---
## What
ACPA-16 and D98(c): FoundationModelsAgents reads its layers from the same `DotfolderStack` list as ACPAgent, and has no `agentFolders` option (AG-10 of FoundationModelsAgents). In the root settings folder, an agent is `<root>/<id>/`, and the settings folders (`_skills/`, `_rules/`) are never a valid agent id.

**Blocked outside this board:** AG-10 must be done in FoundationModelsAgents first. Now `AgentRegistry` has `init(stack:agentFolders:variables:watch:)`, `init(layers:agentFolders:...)` and `init(marketplaces:stack:agentFolders:...)` (`../FoundationModelsAgents/Sources/FoundationModelsAgents/Registry/AgentRegistry.swift:109,135,170`). Do not change FoundationModelsAgents from this board.

Now `AgentsComposition.makeAgentRegistry` (`Sources/FoundationModelsACPAgent/Agent/AgentsComposition.swift:132-142`) uses `DotfolderStack(name: "agents", ...)`.

Do this after AG-10:
- Update the Agents dependency in `Package.swift` / `Package.resolved` to the AG-10 revision.
- `makeAgentRegistry` uses `SettingsFolders.stack(for: .agents, workingDirectory:)` of the previous card. With a root: the user layer is `<root>/`, and names that start with `_` are not agents (confirm the AG-10 rule). With no root: the same layers as now.
- Remove each use of `agentFolders`.
- The launcher start (`ComposedSessionLauncher`, if it exists then; else the session start paths) uses the cwd of the started session for the session layer.

## Acceptance Criteria
- [ ] With a root, an agent in `<root>/<id>/AGENT.md` is in the catalog, and an agent with the same id in the cwd wins.
- [ ] `<root>/_skills/` and `<root>/_rules/` are not agents.
- [ ] With a root, no agent comes from `~` or `XDG_CONFIG_HOME`.
- [ ] With no root, the catalog is the same as before.

## Tests
- [ ] A test with a temporary root and cwd for the three cases above.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-16
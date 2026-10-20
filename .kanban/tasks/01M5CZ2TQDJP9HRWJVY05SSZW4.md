---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d0af7r7vdgcxftt8k3gawe
  text: |-
    AG-10 API, agreed with the FoundationModelsAgents session on 2026-10-20 (sha follows after its push):
    - `AgentRegistry` has no `agentFolders:`. The inits are `init(stack:variables:watch:)`, `init(layers:variables:watch:)` and `init(marketplaces:stack:variables:watch:)`.
    - Each local layer reads `<id>/AGENT.md` and `agents/<id>/AGENT.md`. The root `AGENT.md` of a layer is the default agent. In one layer, `<id>/AGENT.md` wins, and the hidden copy gives an advisory.
    - A child folder whose name is not a valid agent id (`_skills/`, `_rules/`, `_partials/`, `.git/`) is not an agent and gives no diagnostic.
    - With a root: `DotfolderStack(layers: [defaults..., Layer(.user, root: <root>), Layer(.project, root: <cwd>/.agents)])`. The project layer root is the dotfolder, NOT the cwd (confirmed).
    - With no root (the CLI): `DotfolderStack(name: "agents", ...)`, as now. `~/.config/agents/<id>/AGENT.md` is now also an agent.
  timestamp: 2026-10-20T15:54:15.160927+00:00
- actor: claude-code
  id: 01m5d9vzchhxa2gkd10x8nd04m
  text: 'From ^zt60yv4: `AgentsComposition.makeAgentRegistry` already uses `context.settingsFolders.stack(for: .agents, workingDirectory:)` (the card ACPA-16 needs that no stack holds a folder in `~` or XDG when a root is set). With a root, the user layer of the agents stack is `<root>/`, and the project layer is `<cwd>/.agents/`. With the current Agents dependency an agent in the root is `<root>/agents/<id>/AGENT.md`. This card keeps: the AG-10 dependency update, the `<root>/<id>/` layout and the `_` rule, the removal of `agentFolders`, the launcher start, and its tests. The README section "Settings folders" says that `<root>/<id>/` comes with AG-10; update it when this card lands.'
  timestamp: 2026-10-20T18:41:05.937740+00:00
- actor: wballard
  id: 01m5dawj75kznez2c90jv3jrnp
  text: 'AG-10 is pushed: FoundationModelsAgents main eea0d2b. The blocker is gone. AgentRegistry has no agentFolders; the inits are init(stack:variables:watch:), init(layers:variables:watch:), init(marketplaces:stack:variables:watch:). Each local layer reads agents/<id>/AGENT.md and <id>/AGENT.md (the root AGENT.md is the default agent). Note from the Agents session: an old Package.resolved with old Extras, Router and Skills pins does not compile against eea0d2b, so run `swift package update` for those too (and in IntegrationTests/).'
  timestamp: 2026-10-20T18:58:53.797912+00:00
depends_on:
- 01M5CZ1Y88XJXTTF4XCZT60YV4
- 01M5DCV6DGXMS6FGXQ6AEFMPDZ
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
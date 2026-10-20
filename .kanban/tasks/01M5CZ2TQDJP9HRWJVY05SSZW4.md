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
- actor: claude-code
  id: 01m5ddkffh90fv5efgssz7rm9m
  text: |-
    Research and implementation notes (implement step):
    - The production code was already correct before this pass. ^aefmpdz pinned Agents eea0d2b in Package.resolved and IntegrationTests/Package.resolved. ^zt60yv4 made `makeAgentRegistry` use `settingsFolders.stack(for: .agents, workingDirectory:)`. No `agentFolders` stays in Sources, Tests or IntegrationTests.
    - The session start: `ComposedSessionLauncher` does not exist. Both start paths (`SessionSetup.composeSession` for session/new, and `SessionResume` for session/resume) give the cwd of the started session to `CatalogContext`. No change was necessary.
    - New tests in SettingsFoldersTests (section "Agents"). They call `AgentsComposition.makeAgentRegistry` over a temporary root, cwd and XDG_CONFIG_HOME: (1) `<root>/<id>/AGENT.md` is in the catalog and the `<cwd>/.agents/<id>/` copy wins; (2) `<root>/_skills/` and `<root>/_rules/`, each with an AGENT.md, are not agents and give no diagnostic; (3) with a root, no agent comes from `<XDG_CONFIG_HOME>/agents/` (both forms); (4) with no root, the catalog is equal to the catalog of the old `DotfolderStack(name: "agents", ...)`.
    - TDD note: the new tests passed at once, because the earlier cards delivered the behavior. To prove that they can fail, I put the old `DotfolderStack(name: "agents", ...)` back in `makeAgentRegistry` for one run: tests (1) and (3) failed, then I restored the line. Test (2) depends on the AG-10 rule in the dependency, which this board cannot revert. Test (4) is equal to the old stack by design.
    - The suite imports FoundationModelsAgents, which has its own `ToolCatalog`. A private nested `typealias ToolCatalog = FoundationModelsACPAgent.ToolCatalog` in the suite keeps the existing names.
    - Tool note: `files edit file` with `replace_all: true` replaced only one occurrence in each call.
    - Doc comments: AgentsComposition (`compose`, `makeAgentRegistry`) and `ToolCatalog.agentsDotfolderName` now state the `<id>/AGENT.md` and `agents/<id>/AGENT.md` layout, the default agent, the `<cwd>/.agents/` project layer and the `_` rule. README: the agents tool row, the agents paragraph, and the "Settings folders" text that said `<root>/<id>/` comes with AG-10.
    - Card description checkboxes: the update-task call to tick them did not complete in this session (the tool output was too large). All acceptance items and test items are met.
  timestamp: 2026-10-20T19:46:21.809812+00:00
- actor: claude-code
  id: 01m5ddks73gz640rqc2392gaeq
  text: |-
    Correction to the previous comment: the update-task call did complete. The description now has all acceptance and test checkboxes ticked (6/6).

    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsACPAgentTests/SettingsFoldersTests.swift (4 new agent tests, shared `catalogContext` helper), Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift (doc comments only), Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift (doc comment only), README.md (agents layout and Settings folders text). `swift test`: 1074 tests in 118 suites passed, 0 failures, 0 compiler warnings; 1 known issue is the `withKnownIssue` self-test that already existed in HarnessSmokeTests.
    - next: /review
  timestamp: 2026-10-20T19:46:31.779857+00:00
- actor: claude-code
  id: 01m5ddpcqws5b4enbdnvaja503
  text: |-
    ### test — green
    - evidence: swift test (changed files touched first, rebuilt) — 1074 tests in 118 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue, accepted); swift build --build-tests --package-path IntegrationTests — Build complete. Only warning: SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx bundle (accepted). No compiler warning in the changed files.
    - next: review
  timestamp: 2026-10-20T19:47:57.308940+00:00
- actor: claude-code
  id: 01m5ddsj7r0q3hvm9y132hkg2x
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 004c778). 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. The ignore rule excluded 4 .kanban files. No validator matched README.md.
    - next: none. The task is in done.
  timestamp: 2026-10-20T19:49:41.240653+00:00
- actor: wballard
  id: 01m5ddt1mw8rr1d1zsk02a52ed
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files
    - test: green — swift test 1074 passed; IntegrationTests builds
    - commit: 004c778
    - review: clean — 0 findings; task is done
  timestamp: 2026-10-20T19:49:57.020393+00:00
depends_on:
- 01M5CZ1Y88XJXTTF4XCZT60YV4
- 01M5DCV6DGXMS6FGXQ6AEFMPDZ
position_column: done
position_ordinal: fff480
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
- [x] With a root, an agent in `<root>/<id>/AGENT.md` is in the catalog, and an agent with the same id in the cwd wins.
- [x] `<root>/_skills/` and `<root>/_rules/` are not agents.
- [x] With a root, no agent comes from `~` or `XDG_CONFIG_HOME`.
- [x] With no root, the catalog is the same as before.

## Tests
- [x] A test with a temporary root and cwd for the three cases above.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-16
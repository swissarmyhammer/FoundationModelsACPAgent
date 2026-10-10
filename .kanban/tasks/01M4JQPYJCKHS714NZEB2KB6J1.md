---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4kyr1n53wmays933k728ts0
  text: |-
    Research:
    - `composeSession(from:...)` in SessionSetup.swift is the only production `CatalogContext(...)` call. `session/new` and `session/resume` both go through it. The slot switch (`applyModelSlot` in ConfigOptions.swift) does not compose again: the replacement session gets `entry.surface.tools`, which the first composition made.
    - Readers of `CatalogContext.environment`: WebComposition (API keys), `makeSkillsSource` (MarketplaceStore cache and seed folders).
    - Other library readers of the process environment that the session composition reaches: the `skills` and `agents` DotfolderStack in `makeSkillsSource` and `AgentsComposition.makeAgentRegistry` give no `environment:`, thus `DotfolderStack` reads `<NAME>_DEFAULTS_DIR` and `XDG_CONFIG_HOME` from the process. These must use the context environment too.
    - Readers that must stay on the process environment (Multitool API has no environment input): `withEnvironment()` (`tools.environment.variables`; `EnvironmentContext.init` is internal), the shell capability (`ShellRunner` child inherits the process environment), and `StdioServerProcess` (MCP stdio child: `environ` plus the configured `env`).
    - Production hosts (acp-agent `run`/`acp`, `ComposedAgent.compose` default) give `ProcessInfo.processInfo.environment`, thus no behavior change for them. The stub agent of the tests gives `StubAgentDefaultsLayer.makeEnvironment`, thus its sessions no longer read the process environment.
    - The web capability configuration is not public in Multitool, thus a test cannot read the providers of a mounted web tool without a request. The tests prove the path through the marketplace cache and the dotfolder stacks, which read the same `CatalogContext.environment`.
  timestamp: 2026-10-10T22:25:42.053737+00:00
- actor: claude-code
  id: 01m4kzawh4vqkzx78wk9mvf2hs
  text: |-
    Implementation landed (TDD):
    - RED: new suite `AgentEnvironmentTests` (3 tests) failed for the expected reasons: the host cache folder stayed empty, and the skill and agent of the host defaults layers were absent, in the first session and after the slot switch.
    - GREEN: `composeSession(from:...)` gives `environment: environment` to `CatalogContext`; the `skills` stack (`ToolCatalog.makeSkillsSource`) and the `agents` stack (`AgentsComposition.makeAgentRegistry`) give `environment: context.environment` to `DotfolderStack`. The 3 tests pass.
    - Comments record the 3 readers that stay on the process environment (Multitool gives no environment input): `withEnvironment()` (`tools.environment.variables`), the shell capability, and the stdio MCP spawn (`MCPComposition.envVariables`).
    - Docs updated: `CatalogContext.environment`, `RoutedACPAgent.environment`, `WebComposition`, `makeRegistry`.
    - Test support: `makeStubAgent(... environment:)` adds keys below the defaults layer key; `StubAgentDefaultsLayer.environmentKeySuffix` is public.
    - No test reads a mounted web tool: Multitool keeps the web configuration private, and a request needs the network. The marketplace and dotfolder tests prove the same `CatalogContext.environment` path.
  timestamp: 2026-10-10T22:35:59.396067+00:00
- actor: claude-code
  id: 01m4kzvt37v6ywsj0s1xp481x5
  text: |-
    Test runs (all with `--scratch-path .build/alt --force-resolved-versions`, `SKILLS_MARKETPLACE_CACHE` set to an empty scratch folder):
    - `--filter AgentEnvironmentTests`: RED 3 of 3 failed (expected reasons); GREEN 3 of 3 passed.
    - Full root suite, run 1: 885 of 886 passed; `AgentsToolTests.closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses` hit its 60 s limit. Alone it passes in 0.95 s. The change does not touch its path. Recorded as new task ^05rmb1p.
    - Full root suite, run 2 (no code change): 886 tests in 97 suites passed, 1 known issue (harness self-test), exit 0.
    - IntegrationTests (`--package-path IntegrationTests --scratch-path IntegrationTests/.build/alt --no-parallel`): 12 suites passed, no failure.
    - The one build warning is the SwiftPM `missing creator for mutated node` line for the `mlx-swift_Cmlx.bundle` of a dependency. It is in each run, also before this change. No compiler warning.

    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift, Sources/FoundationModelsACPAgent/Tools/CatalogContext.swift, Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Sources/FoundationModelsACPAgent/Tools/WebComposition.swift, Tests/FoundationModelsACPAgentTestSupport/StubProfileFixtures.swift, Tests/FoundationModelsACPAgentTests/AgentEnvironmentTests.swift (new)
    - next: /review
  timestamp: 2026-10-10T22:45:13.959491+00:00
- actor: claude-code
  id: 01m4m32nd0ctnqzsr7a4gzf3g6
  text: |-
    ### test — green
    - evidence: `swift test --scratch-path .build/alt --force-resolved-versions` — 886 tests in 97 suites passed, 0 failed, 1 known issue (the intentional withKnownIssue in HarnessSmokeTests). `swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions` — 33 tests in 12 suites passed, 0 failed. SKILLS_MARKETPLACE_CACHE was set to an empty scratch folder for each run. The only warning is the mlx-swift_Cmlx.bundle "missing creator for mutated node" build warning (dependency). AgentsToolTests.closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses passed in 11.490 seconds. No file was changed.
    - note: my first unit run was in a blocking shell call; the tool aborted it after 1800 s with no output. I stopped only that run (my own swift-test pid 96385 and its test helper). I ran it again in the background and the suite then finished in 17.9 s. I did not touch the orphan checkout or its indexer processes.
    - next: none
    task: ^b2kb6j1
  timestamp: 2026-10-10T23:41:24.256835+00:00
position_column: doing
position_ordinal: '80'
title: Give the agent environment to the CatalogContext of each session composition
---
## Problem

`RoutedACPAgent.composeSession(from:workingDirectory:additionalRoots:clientMCPServers:)` (`Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift`) makes its `CatalogContext` with no `environment:` argument. Thus `CatalogContext.environment` is `ProcessInfo.processInfo.environment`, not `RoutedACPAgent.environment`. The web capability reads its API keys from `CatalogContext.environment` (task ^ba231ka). A host or a test that gives the agent an environment does not reach the web capability.

Found during task ^c4a6mwy (2026-10-10). Not changed there, because it is outside that task.

## What to change

- Decide if the session composition must give `environment: environment` to `CatalogContext`. Check the callers that depend on the process environment (bench, `ComposedAgent`, the stub agent with `StubAgentDefaultsLayer.makeEnvironment`).
- Add a test that fails when the agent environment does not reach `CatalogContext.environment`.

## Decision

- The session composition gives `environment: environment` (the host environment of the agent) to `CatalogContext`. `session/new` and `session/resume` compose through `composeSession(from:...)`. A model-slot switch composes nothing: the replacement session gets the tools of the first composition.
- The `skills` and `agents` dotfolder stacks of a session read `<NAME>_DEFAULTS_DIR` and `XDG_CONFIG_HOME` from `CatalogContext.environment` too (they read the process environment before).
- Three readers stay on the process environment, because Multitool gives no environment input for them. A code comment records each: `withEnvironment()` (`tools.environment.variables`; `EnvironmentContext.init` is internal), the shell capability, and the stdio MCP spawn (`StdioServerProcess` builds from `environ`).
- The callers that give the process environment keep their behavior: the `acp-agent` CLI commands and the default of `ComposedAgent.compose(environment:)` and `RoutedACPAgent.init(environment:)` give `ProcessInfo.processInfo.environment`. The stub agent gives `StubAgentDefaultsLayer.makeEnvironment`, thus its sessions no longer read the process environment.

## Acceptance

- [x] The decision is recorded, and a test proves the chosen behavior. Tests (`Tests/FoundationModelsACPAgentTests/AgentEnvironmentTests.swift`), each for the first session and after a slot switch:
  - `theMarketplaceStoreOfEachSessionUsesTheCacheFolderOfTheHostEnvironment` (`SKILLS_MARKETPLACE_CACHE` reaches the marketplace store of `CatalogContext.environment`)
  - `theSkillsStackOfEachSessionReadsTheDefaultsLayerOfTheHostEnvironment` (`SKILLS_DEFAULTS_DIR`)
  - `theAgentsStackOfEachSessionReadsTheDefaultsLayerOfTheHostEnvironment` (`AGENTS_DEFAULTS_DIR`)
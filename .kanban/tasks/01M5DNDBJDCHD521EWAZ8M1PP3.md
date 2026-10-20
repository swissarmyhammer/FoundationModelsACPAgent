---
comments:
- actor: claude-code
  id: 01m5dngxt675dvrmmqbxw0wpje
  text: |-
    Research (implement):
    - This repository builds one `MarketplaceStore` only: `ToolCatalog.makeSkillsSource(context:)`. It reads the cache folder from `MarketplaceStore.cacheDirectory(environment: context.environment)`.
    - The agents marketplace builds no store of its own. `AgentsComposition.makeAgentRegistry(context:marketplaces:)` reads the started store of the skills source. Thus the agents get the same folder with no other change.
    - `doctor` (`Doctor/RuntimeDoctor.swift`, `Sources/acp-agent`) builds no `MarketplaceStore`. Nothing to change there.
    - The store reads only the seed folder (`SKILLS_MARKETPLACE_SEED`) from its `environment:` argument (FoundationModelsExtras `MarketplaceStore.init`). The cache folder is an init argument. Thus no family package needs a change.
    - Plan: `ComposedAgent.compose(skillsMarketplaceCacheDirectory:)` -> `RoutedACPAgent.init(skillsMarketplaceCacheDirectory:)` -> stored property -> `CatalogContext(skillsMarketplaceCacheDirectory:)` in `composeSession` -> `makeSkillsSource` uses `context.skillsMarketplaceCacheDirectory ?? MarketplaceStore.cacheDirectory(environment:)`.
  timestamp: 2026-10-20T22:04:46.790165+00:00
- actor: claude-code
  id: 01m5dnr8xkz04cm6sy3cwphcv0
  text: |-
    Implementation landed (TDD):
    - RED: `theFolderOfTheHostWinsOverTheCacheFolderOfTheEnvironment` and `theSkillsMarketplaceCacheOfAGivenFolderWinsOverTheEnvironment` failed for the expected reason (the folder of the host stayed empty, the folder of the environment got the cache) while the parameter was carried but not used. The test with no environment variable did not run at RED, because at RED it writes into the default cache under the home folder; it ran at GREEN.
    - GREEN: `ToolCatalog.makeSkillsSource` uses `context.skillsMarketplaceCacheDirectory ?? MarketplaceStore.cacheDirectory(environment:)`.
    - Path: `ComposedAgent.compose(skillsMarketplaceCacheDirectory:)` -> `RoutedACPAgent.init(skillsMarketplaceCacheDirectory:)` (public stored property) -> `composeSession` -> `CatalogContext(skillsMarketplaceCacheDirectory:)`.
    - Other store sites: the agents marketplace reads the same store (`AgentsComposition.makeAgentRegistry`), thus it uses the same folder. `doctor` builds no `MarketplaceStore`. No family package needed a change.
    - Test helpers: `composeStubAgent` got `skillsMarketplaceCacheDirectory:` and `environment:` (extra pairs). `SkillsMarketplaceTests.makeContext` got `cache: URL?` and `skillsMarketplaceCacheDirectory:`. The new shared `SkillsMarketplaceTests.marketplaceConfiguration(repository:)` replaces the inline YAML in `AgentEnvironmentTests`.
    - DocC symbol links of `compose(...)` updated in ComposedAgent.swift, GatedStubModel.swift and acp-agent/AgentComposition.swift.
    - Full `swift test`: 1169 tests in 126 suites passed, 1 known issue (the existing `withKnownIssue` in HarnessSmokeTests). The one build line `warning: missing creator for mutated node: ... mlx-swift_Cmlx.bundle` is a SwiftPM build-graph message about the mlx bundle, not a compiler warning of this code.
  timestamp: 2026-10-20T22:08:47.539401+00:00
- actor: claude-code
  id: 01m5dnrds8727wdtdf647jpr0s
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsACPAgent/ComposedAgent.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/Tools/CatalogContext.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Sources/FoundationModelsACPAgent/Configuration/GatedStubModel.swift, Sources/acp-agent/AgentComposition.swift, Tests/FoundationModelsACPAgentTestSupport/StubComposition.swift, Tests/FoundationModelsACPAgentTests/{SkillsMarketplaceTests,ComposedAgentTests,AgentEnvironmentTests}.swift; `swift test` 1169 tests in 126 suites passed, 1 known issue (existing), 3 new tests.
    - next: review
  timestamp: 2026-10-20T22:08:52.520185+00:00
- actor: claude-code
  id: 01m5dnrtb5jjertq94ne36mq8d
  text: 'Correction to the step record above: the count of changed files is 11, not 9 (7 source files, 1 test support file, 3 test files). The list of paths in that record is complete.'
  timestamp: 2026-10-20T22:09:05.381092+00:00
- actor: claude-code
  id: 01m5dnvgxt49des8whcwedg963
  text: |-
    ### test — green
    - evidence: touched the 11 changed files, then `swift test`: 1169 tests in 126 suites passed, 1 known issue (the accepted withKnownIssue in HarnessSmokeTests), 0 failed, 0 skipped, 0 compiler warnings or errors in the output. `swift build --build-tests --package-path IntegrationTests`: Build complete, only the accepted "missing creator for mutated node" warning on mlx-swift_Cmlx.
    - next: review
  timestamp: 2026-10-20T22:10:34.042575+00:00
position_column: doing
position_ordinal: '8180'
title: The host gives the skills marketplace cache directory
---
## What
Split from ^8c4f0pa (2026-10-20): the model cache part of that card waits for FoundationModelsExtras and FoundationModelsRouter, but the skills marketplace part can go now.

The app gives each folder in Application Support (request of the TestudoApp session). Now the skills marketplace cache can be set only through `SKILLS_MARKETPLACE_CACHE` in the `environment:` argument of `ComposedAgent.compose` (`MarketplaceStore.cacheDirectory(environment:)`, `ToolCatalog.swift:567`; `MarketplaceStore(cacheDirectory:)` takes a folder).

Do this:
- Add `skillsMarketplaceCacheDirectory: URL? = nil` to `ComposedAgent.compose`, and carry it to `CatalogContext` (and the `RoutedACPAgent` init if that is the path), in the pattern of `hooksDataDirectory`.
- A given value wins over `SKILLS_MARKETPLACE_CACHE`. With nil, nothing changes.
- Document on the parameter that the app gives a folder in Application Support.
- Check each other place that builds a `MarketplaceStore` (for example `doctor`, the agents marketplace) and give it the same folder.

## Acceptance Criteria
- [x] With the parameter, the marketplace store uses that folder, also when `SKILLS_MARKETPLACE_CACHE` is set.
- [x] With no value, nothing changes.

## Tests
- [x] A test with a temporary folder, and one with `SKILLS_MARKETPLACE_CACHE` set to another folder.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-16
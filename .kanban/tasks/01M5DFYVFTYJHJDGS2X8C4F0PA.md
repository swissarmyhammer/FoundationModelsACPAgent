---
comments:
- actor: claude-code
  id: 01m5dncdt05frjznxyavj1bge0
  text: |-
    Research: the live model download location cannot be given from ACPAgent. This is the stop condition of the card.

    The chain of the live download:
    1. `ComposedAgent.makeRouter` (ACPAgent) makes `Router(recordingsDir:loader: LiveModelLoader(), hooks:)`.
    2. FoundationModelsRouter `LiveModelLoader.init(reporting:)` (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift) is the only public init. It always uses `MLXModelLoader()`. The init that takes a loader, `init(reporting:modelLoader:)`, is `package`, thus ACPAgent cannot call it.
    3. FoundationModelsExtras `MLXModelLoader.init(tokenizerLoader:)` (Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift) uses `HubCache.default`. The init `init(cache:tokenizerLoader:)` is internal. Also, that `cache` is used only to measure the weights. The download in `load(key:progressHandler:)` uses `#hubDownloader()` with no argument.
    4. mlx-swift-lm `#hubDownloader()` expands to `HubClient()`. swift-huggingface `HubClient()` uses `HubCache.default`, which reads `HF_HUB_CACHE` and `HF_HOME` from `ProcessInfo.processInfo.environment`.

    Thus the `environment:` argument of `ComposedAgent.compose` does not reach the download now, and a `modelCacheDirectory` parameter cannot reach it either. The same is true on the current `main` of the sibling repositories (Router d2e4bdb, Extras 03ceab8).

    The missing API:
    - FoundationModelsExtras: a public `MLXModelLoader.init(cache: HubCache, tokenizerLoader:)` (or `cacheDirectory: URL`), and `load` must give that cache to the downloader: `#hubDownloader(HubClient(cache: cache))` (with the host and the token provider of `HubClient()`).
    - FoundationModelsRouter: a public `LiveModelLoader.init(reporting:cacheDirectory:)`, or a public `init(reporting:modelLoader:)`, that gives the folder to `MLXModelLoader`.

    Other facts:
    - `ModelResolver` (Doctor/ModelResolver.swift) and `doctor` (Sources/acp-agent/DoctorCommand.swift) read the cache through `SystemModelResolver.hubCacheDirectory(environment:)`. These can take a folder from ACPAgent.
    - The skills marketplace cache can take a folder from ACPAgent: `MarketplaceStore(... cacheDirectory: ...)` in `ToolCatalog` (Tools/ToolCatalog.swift).
    - `Router.init(cacheDir:)` is a second cache: the sizing metadata, default `<Caches>/FoundationModelsRouter`. ACPAgent does not give it for the live path now.

    No file was changed. The skills and resolver parts were not started, because the card says to stop, and a `modelCacheDirectory` that does not move the download would not agree with its acceptance criteria. A person must decide: make a card on Extras and Router for the API above (discuss first), then start this card again, or split the skills part into its own card.
  timestamp: 2026-10-20T22:02:19.328678+00:00
- actor: claude-code
  id: 01m5dncghff2fjzmkqs3q7qbfx
  text: |-
    ### implement — stuck
    - evidence: no file changed. Missing API: public cache folder on FoundationModelsExtras `MLXModelLoader` (init(cache:) is internal, and `load` uses `#hubDownloader()` = `HubClient()` = `HubCache.default` from ProcessInfo) and on FoundationModelsRouter `LiveModelLoader` (`init(reporting:modelLoader:)` is `package`).
    - next: a person decides: add the API on Extras and Router (a card on each project, discussed first), or split the skills marketplace part into its own card.
  timestamp: 2026-10-20T22:02:22.127183+00:00
- actor: wballard
  id: 01m5dndbnwegpx058xp2ed300c
  text: 'Planner decision (2026-10-20): the skills marketplace part moves to a new card. This card keeps only the model cache (`modelCacheDirectory`), and it waits for FoundationModelsExtras (a public `MLXModelLoader` init that takes the hub cache folder, and `load` gives it to the downloader) and FoundationModelsRouter (a public `LiveModelLoader.init(reporting:cacheDirectory:)` or a public `init(reporting:modelLoader:)`). The resolver and `doctor` must use the same folder as the download, so do them in this card after both pushes.'
  timestamp: 2026-10-20T22:02:49.916450+00:00
- actor: claude-code
  id: 01m5ey98z943e0wbba4mcgza5q
  text: |-
    Research (after the pushes of Extras 6670bc0 and Router f055e69):
    - `swift package update FoundationModelsRouter FoundationModelsExtras` resolves Extras at 6670bc0 and Router at f055e69, in the root package and in IntegrationTests.
    - Router now has `LiveModelLoader.init(reporting:cacheDirectory:)`. It gives the folder to Extras `MLXModelLoader(cacheDirectory:)`, which makes `HubCache(cacheDirectory:)`. That folder is the hub cache itself (it holds `models--<owner>--<repo>`), the same folder as `HF_HUB_CACHE`, and the same as `SystemModelResolver.cacheDirectory`. With `nil`, the loader uses `HubCache.default`, which reads `HF_HUB_CACHE` and `HF_HOME` from the process environment, not from the `environment:` argument of `compose`. That stays the same.
    - Places that use the model cache in ACPAgent: `ComposedAgent.makeRouter` (live path, `LiveModelLoader()`), `SystemModelResolver.init(environment:)` / `hubCacheDirectory(environment:)` (Doctor/ModelResolver.swift), and `AcpAgentCommand.Doctor.components` (the resolver and the free-disk figure of the cache, Sources/acp-agent/DoctorCommand.swift).
    - The router keeps its loader private, and the loader keeps its cache private. A unit test with no network can read the folder of the live loader only with `Mirror` (path `modelLoader.cache.cacheDirectory`; all three types are structs).
    - Plan: `compose(... modelCacheDirectory:)` -> `makeRouter` -> `LiveModelLoader(cacheDirectory:)`; `SystemModelResolver.init(environment:modelCacheDirectory:)` and `hubCacheDirectory(environment:modelCacheDirectory:)` where a given folder wins; `Doctor.components(... modelCacheDirectory:)`. The CLI gives no value.
  timestamp: 2026-10-21T09:57:07.689746+00:00
- actor: claude-code
  id: 01m5eyn4x3n46487m3k2c6nxhe
  text: |-
    Implementation done (TDD: the three tests with a given folder failed first, the three tests with no folder passed; then all six passed).
    - `ComposedAgent.compose(... skillsMarketplaceCacheDirectory:modelCacheDirectory:reporting:)`: the new parameter goes to `makeRouter`, then to the new internal `makeLiveModelLoader(modelCacheDirectory:)`, which makes Router `LiveModelLoader(cacheDirectory:)`. The doc says: an app gives a folder in Application Support, macOS can delete a folder in Caches, the CLI gives no value.
    - `RoutedACPAgent` and `CatalogContext` do not get the value: they do not use it. Only the router loads models, and `compose` makes the router. A host that makes its own router gives `LiveModelLoader(cacheDirectory:)` itself.
    - `SystemModelResolver.init(environment:modelCacheDirectory:)` and `hubCacheDirectory(environment:modelCacheDirectory:)`: a given folder wins over `HF_HUB_CACHE` and `HF_HOME`. With `nil`, the old order stays.
    - `AcpAgentCommand.Doctor.components(... modelCacheDirectory:)`: the resolver and the free-disk figure use the given folder. The `doctor` command gives no value.
    - The doc links of the `compose` signature in ComposedAgent.swift, GatedStubModel.swift and AgentComposition.swift now name `modelCacheDirectory:`.
    - Tests: Tests/FoundationModelsACPAgentTests/ModelCacheDirectoryTests.swift, 6 tests, no network. The router loader and `ProfileDoctor` keep the folder private, so the tests read it with `Mirror` (path `modelLoader.cache.cacheDirectory` for the loader). If Router or Extras renames these private properties, the two live-loader tests fail and must get the new path.
    - One limit: the live loader reads `HF_HOME` from the process environment, not from the `environment:` argument. Thus no unit test sets `HF_HOME` for the download: to set it, a test must change the environment of the whole test process. The download test proves that the loader holds the given folder. Extras documents that `MLXModelLoader(cacheDirectory:)` uses that folder also when `HF_HUB_CACHE` or `HF_HOME` is set. The resolver and doctor tests set both variables to other folders.
    - The title no longer says "(waits for Extras and Router ^1056ce6)".
  timestamp: 2026-10-21T10:03:36.739029+00:00
- actor: claude-code
  id: 01m5eynn8ezykm18y9fb9gggbx
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/ComposedAgent.swift, Sources/FoundationModelsACPAgent/Doctor/ModelResolver.swift, Sources/FoundationModelsACPAgent/Configuration/GatedStubModel.swift (doc link), Sources/acp-agent/DoctorCommand.swift, Sources/acp-agent/AgentComposition.swift (doc), Tests/FoundationModelsACPAgentTests/ModelCacheDirectoryTests.swift (new). `swift build`: no warnings except the known build-system note "missing creator for mutated node" of the mlx-swift bundle. `swift test`: 1175 tests in 127 suites passed, 0 failures (1 known issue, the deliberate `withKnownIssue` in HarnessSmokeTests). `swift build --package-path IntegrationTests --build-tests`: complete. Not committed.
    - open: the acceptance line of `skillsMarketplaceCacheDirectory` stays unchecked here. The planner moved it to ^z8m1pp3 (commit c11d914).
    - next: /review
  timestamp: 2026-10-21T10:03:53.486341+00:00
position_column: doing
position_ordinal: '80'
title: The host gives the model cache directory
---
## What
The TestudoApp session asks (2026-10-20): the app gives each folder in Application Support. With a root settings folder (ACPA-16), three folders that are not settings can still be in the home folder. `hooksDataDirectory` is done (^44qdn4g). The other two can be set now only through environment variables in the `environment:` argument of `ComposedAgent.compose`:
- the skills marketplace cache: `SKILLS_MARKETPLACE_CACHE` (`MarketplaceStore.cacheDirectory(environment:)`, `ToolCatalog.swift:567`);
- the model cache: `HF_HOME` (`ModelResolver.hubCacheDirectory(environment:)`, `Doctor/ModelResolver.swift:56`), and the folder that the live model source downloads to.

Do this:
- Add `skillsMarketplaceCacheDirectory: URL? = nil` and `modelCacheDirectory: URL? = nil` to `ComposedAgent.compose` (and to the `RoutedACPAgent` init or `CatalogContext` where the value is used). When a value is given, it wins over the environment variable. When it is nil, the behavior is the same as now.
- Find each place that reads or writes the model cache: the resolver, `doctor`, and the live model source (the download). If the download location is chosen inside FoundationModelsRouter or a model package and cannot be given from ACPAgent, stop and report `stuck` with the exact API that is missing. Do not change that package.
- Document on each parameter that the app gives a folder in Application Support, and that macOS can delete a folder in Caches.
- The CLI gives nothing, so its behavior does not change.

## Acceptance Criteria
- [ ] With `skillsMarketplaceCacheDirectory`, the marketplace store uses that folder, also when `SKILLS_MARKETPLACE_CACHE` is set.
- [x] With `modelCacheDirectory`, the resolver, `doctor` and the live download use that folder, also when `HF_HOME` is set.
- [x] With no values, nothing changes.

## Tests
- [x] A test for each parameter with a temporary folder, and one with the environment variable set to another folder.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-16
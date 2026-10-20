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
position_column: doing
position_ordinal: '80'
title: The host gives the model cache directory (waits for Extras and Router ^1056ce6)
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
- [ ] With `modelCacheDirectory`, the resolver, `doctor` and the live download use that folder, also when `HF_HOME` is set.
- [ ] With no values, nothing changes.

## Tests
- [ ] A test for each parameter with a temporary folder, and one with the environment variable set to another folder.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-16
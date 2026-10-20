---
position_column: todo
position_ordinal: 8d80
title: The host gives the skills marketplace cache and the model cache directories
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
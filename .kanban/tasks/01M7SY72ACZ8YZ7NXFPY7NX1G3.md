---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7t328gdq5rvksxqar3g1jf1
  text: |-
    Dependency available (2026-11-19): FoundationModelsMetadataRegistry D207 work is on main at f6d72592ef4221f70833bcf2d2484407be110330.
    API:
    - `CatalogPersistence(folder: URL, embeddingModelID: String)`; `await MetadataSearcher<Item>(persistence:mode:weights:embedder:selection:decision:onDiagnostic:)` (Item: Codable); `SharedCatalogEmbedding(persistence:embedder:onDiagnostic:) async`; call `waitForSaves()` before the process exits.
    - `update(upserting: [Item], removing: [String] = [])`: a replaced item keeps its place, a new item goes to the end, an id in both lists is an upsert. `update(items:)` stays.
    - The start reads items and vectors with no embed; entries stored with no vector are embedded in the background. Old format, another model id or a damaged store: dropped with `.storedCatalogDropped(reason:)`; the searcher starts empty, and the next update builds it again. A failed write gives `.catalogSaveFailed`.
    - Saves run on a background queue after each change and each embed chunk (chunks of 256). ONLY ONE searcher (or one shared-embed group) for each folder.
    - Cost gate at 100,000 items (Benchmarks/Results/2026-11-19-scale): a search with limit = catalog size 85 ms max; an update of 20 items 11 ms max; a start 1.1 s; about 1.65 GiB resident after a start. The ranking does not change.
    Log the diagnostics with ACPAgentTelemetry. This task can start.
  timestamp: 2026-11-19T14:23:43.117288+00:00
- actor: claude-code
  id: 01m7t3m05htdrhqf4dmq41zpk9
  text: |-
    Blocker (2026-11-19): the first try stopped with no code change, because the registry at f6d72592 had no public read of the stored items. Without it the index cannot rebuild its session list after a restart: the reconcile cannot give only the changed items, a session deleted while the agent was off stays in the store, and allTurns(), items(of:) and a query with only tokens lose the sessions of folders that the process cannot read.
    RESOLVED: the registry public catalog read is on main at 6514a9531c2b657f7e79484350628689a61a3240: `public func items() -> [Item]` and `public func ids() -> [String]` on `MetadataSearcher` (actor methods, catalog order). For a searcher made with `CatalogPersistence`, they return the stored catalog as soon as the async init returns, before any embed ends. After the init, rebuild the session list from `items()` one time.
    Also: in a new worktree, `swift package update` clones each dependency again, also the large llama.cpp submodule; this is slow but not stalled. Prefer to run this task in the main tree, or reuse the first worktree.
  timestamp: 2026-11-19T14:33:24.401870+00:00
depends_on:
- 01M7SY663TJBRCSAEXBJEX3G34
position_column: todo
position_ordinal: '9180'
title: 'D207: persist the transcript search catalog with the registry, and measure 1,000 sessions'
---
Decision D207. Brief: `/Users/wballard/github/swissarmyhammer/.briefs/search/acpa-brief.md`, change step 5 and the last test. Overview: `overview.md` ("Across launches").

## Dependencies

- ^jex3g34 (the TranscriptSearchIndex).
- FoundationModelsMetadataRegistry on `main` with the persistence of its catalog and vectors, the update of some items, and the cost gate at 100,000 items (`mdr-brief.md`). Not on this board, and the registry session is not running yet: wait for the sha.

## Change

1. Give the searcher the persistence option of the registry, with the folder `<AgentHome.local>/session-search/server/` (a new folder name constant on `AgentHome`, as `codeContextFolderName`) and the model id of the `embedding` slot. Keep no other search file. The app's instance uses `.../client/`.
2. Use the registry's update of some items in the update path (replace the full-list `update(items:)`).
3. After launch, the searcher starts from its stored catalog; the reconcile then gives only the changed items.

## Tests

- A new agent over the same folder searches with no embed.
- A change of the embedding model id rebuilds the vectors.
- Measure with a realistic history (for example 1,000 sessions): the time of a search and of a turn update. Report the numbers to the TestudoApp session (testudoapp-9a). Do not change the design; the limits are in `mdr-brief.md`. #d207 #search
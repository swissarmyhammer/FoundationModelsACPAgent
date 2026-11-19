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
- actor: claude-code
  id: 01m7t6sv6hw9jsn286thn62b7e
  text: |-
    ### review — findings
    - evidence: review sha 51740b3~1..51740b3 (merged on main at 9647944). 3 findings, 3 confirmed, 1 refuted, 7 engine tasks attempted, 0 failed. Sources/FoundationModelsACPAgent/Search/TranscriptSearchIndex.swift:166, Tests/FoundationModelsACPAgentTests/TranscriptSearchMeasurementTests.swift:23, Tests/FoundationModelsACPAgentTests/TranscriptSearchMeasurementTests.swift:178. ARCHITECTURE.md is not reviewed: no validator matches it.
    - next: Correct the 3 open items in "Review Findings (2026-11-19 09:23)". Then run the review again. The task stays in review.
  timestamp: 2026-11-19T15:29:01.649838+00:00
- actor: claude-code
  id: 01m7t71tsa011q3sdwzf6bgs7q
  text: |-
    Picked up the 3 findings of "Review Findings (2026-11-19 09:23)". Plan:
    1. TranscriptSearchIndex: the init only stores its arguments (not async). A new `public func load() async` makes the searcher, reads the stored items, sets the sessions and writes the stray ids. A state enum (notLoaded / loading(Task)) holds the load, so no stored Optional waits for a later fill. Each other method awaits the same load (it starts the load when no call started it). `waitForSaves()` before a load reads nothing. RoutedACPAgent.init calls `load()` after it makes the index. The Mac app has no TranscriptSearchIndex call site yet (grep of the sibling repos): the doc comment tells the app to call `load()` for the client instance.
    2. The measurement moves to a new nested package `Benchmarks/` (path dependency `..`, as the registry Benchmarks and the IntegrationTests package do). It is a test target that `swift test --package-path Benchmarks` selects. No environment variable. The root manifest and ci.yml do not name it; ci.yml and the README state that it runs only on demand. CountingEmbedding and WordBucketEmbedding move to the TestSupport target, so the unit tests and the benchmark share one copy. The benchmark uses only the public API (no @testable).
    3. The report goes to swift-log `Logger` (a logging system), not print.
  timestamp: 2026-11-19T15:33:23.370295+00:00
- actor: claude-code
  id: 01m7t87f12tbjz9jxz255kyens
  text: |-
    Implementation landed (no commit). Discoveries:
    - RoutedACPAgent.init cannot call a method on self.transcriptSearchIndex before every stored property is set. It makes a local index, calls load(), and then assigns it.
    - SessionSearchQuery and SessionSearchRequest come from FoundationModelsMultitool, and ULID comes from the re-export in FoundationModelsRouter. The Benchmarks manifest declares both.
    - Package.resolved is gitignored at every level. Copy the root Package.resolved into Benchmarks/ before the first resolve, so the registry stays at 6514a95.
    - A clean build of the Benchmarks package shows clang and C++ interop warnings that come only from third-party checkouts (mlx-swift, libgit2). This repository's code has no warning.
    - The Mac app has no TranscriptSearchIndex call site yet. When the app adds the client instance, it must call load().
    Benchmark numbers (debug build, swift test --package-path Benchmarks --scratch-path Benchmarks/.build, 1,000 sessions x 10 turns, 41,000 items, fake embed 200 us a text):
    - first build 33,059 ms (41,000 texts embedded), save 66 ms
    - search "dba" median 338.0 / max 348.3 ms (registry matches alone 173.2 / 182.6 ms)
    - search "dtba" 324.3 / 334.0 ms (153.7 / 161.7 ms)
    - search "lba stea" 342.8 / 353.0 ms (175.2 / 183.2 ms)
    - search "from:tool" 204.0 / 214.5 ms (141.4 / 144.8 ms)
    - turn update (4 new chunks, with embed) median 23.2 / max 28.1 ms
    - load of the stored catalog 1,598 ms, first search after it 326.9 ms, texts embedded 1 (the query only)
  timestamp: 2026-11-19T15:53:56.514392+00:00
- actor: claude-code
  id: 01m7t87fk75fbd7djth60y9sds
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Search/TranscriptSearchIndex.swift, TranscriptSearchIndex+Search.swift, RoutedACPAgent.swift; Tests/FoundationModelsACPAgentTestSupport/CountingEmbedding.swift and WordBucketEmbedding.swift (moved from the unit target, now public); 6 TranscriptSearch*Tests.swift files; Benchmarks/Package.swift, Benchmarks/README.md, Benchmarks/Tests/TranscriptSearchBenchmarks/TranscriptSearchMeasurementTests.swift (moved, no env var, Logger in place of print); Package.swift, IntegrationTests/Package.swift (comment), .github/workflows/ci.yml (comment), README.md, ARCHITECTURE.md. The 3 findings are checked.
    - next: review
    ### test — green
    - evidence: swift build --build-tests: Build complete!, 0 compiler warnings. swift test --skip-build: 2593 tests in 269 suites passed, 1 known issue (withKnownIssue in HarnessSmokeTests). The new load tests in TranscriptSearchPersistenceTests: 15/15 passed. Benchmarks: Build complete!, 1 test passed (numbers in the comment above).
    - next: /review
  timestamp: 2026-11-19T15:53:57.095371+00:00
depends_on:
- 01M7SY663TJBRCSAEXBJEX3G34
position_column: doing
position_ordinal: '8180'
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

## Review Findings (2026-11-19 09:23)

> Scope: `review sha 51740b3~1..51740b3` — reviewed the diffs only — lines this change added or modified. 15 file(s) reviewed, 1 not reviewed.

> 1 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Search/TranscriptSearchIndex.swift:166` `swift/initialization` — The init of TranscriptSearchIndex does slow work. It creates a MetadataSearcher that reads the stored catalog from the folder, then calls searcher.items() and writes the stray ids, all before the init returns. The rule says an init must not open a database or read a large file. Such work belongs in an explicit load or start call that the host makes. Keep the init to stored property assignments. Add an explicit `public func load() async` that creates the searcher, reads the stored items, sets `sessions`, and writes the stray ids. Call it from RoutedACPAgent.init after construction. If the design needs the stored catalog loaded at once, document that choice as a deliberate exception in the init doc comment and keep the read in one place.
- [x] `Tests/FoundationModelsACPAgentTests/TranscriptSearchMeasurementTests.swift:23` `test-integrity/test-partitioning` — The whole measurement suite is switched by the environment variable TRANSCRIPT_SEARCH_MEASUREMENT. The suite runs only when that variable equals "1", so the default test run and CI skip it. The rule forbids an environment variable that selects or skips a test. The measurement should be its own test target or package, selected by the platform test tool, and not a test that an environment variable enables. Move TranscriptSearchMeasurementTests into a separate target or nested package (for example a `Measurement` package or a benchmark target) that the platform test tool selects directly, such as `swift test --package-path ...`. Remove the environment-variable gate from the suite. Add a CI task that runs that target, or state explicitly that it runs only on demand.
- [x] `Tests/FoundationModelsACPAgentTests/TranscriptSearchMeasurementTests.swift:178` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
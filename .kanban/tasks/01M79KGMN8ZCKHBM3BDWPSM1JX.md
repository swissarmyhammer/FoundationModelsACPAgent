---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m79kr88531wrqrg60vdks3m3
  text: |-
    Research:
    - `swift package update FoundationModelsMultitool` (root and IntegrationTests) moved only Multitool: abca4236 to 9d46b0fa. No other family package moved. Note: `Package.resolved` is in `.gitignore`, thus the pin change does not show in `git diff`.
    - Multitool 9d46b0fa: `SearchIndexCache.sharedEmbedding(for:embedder:)` keys a slot by catalog entries and embedder identity. Identity is `IdentifiedEmbedding.embeddingIdentity`, or `ObjectIdentifier` of a class instance, else nil (no slot, no share). The cache is process-wide (`SearchIndexCache.shared`, capacity 8) and is not injectable from this package (the `indexCache:` overload is internal).
    - Test seam: the public API is sufficient. `StubModelLoader.makeEmbeddingContainer` gives a `RecordingEmbeddingContainer` (TestSupport), and `ToolCatalogTests.theSessionSurfaceHandsTheProfileEmbedderToSearchTools` already counts the catalog batch through `ToolCatalog.sessionSurface` plus one `searchTools` call. The new tests use the same seam.
  timestamp: 2026-11-13T04:48:15.621588+00:00
- actor: claude-code
  id: 01m79mhrwjex2h6dtd4kknt6qe
  text: |-
    Blocker: the conformance makes HotResumeTests fail some of the time, and the test of this card is flaky in the full suite.

    Done (not committed, in the working tree):
    - Pin: FoundationModelsMultitool abca4236 -> 9d46b0fa in Package.resolved and IntegrationTests/Package.resolved. No other package moved. Package.resolved is gitignored.
    - Sources/FoundationModelsACPAgent/Tools/ProfileEmbedding.swift: conforms to IdentifiedEmbedding, `embeddingIdentity` is `ObjectIdentifier(embedder)`, with the doc comment of the card.
    - Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift: `twoSessionsOfOneProfileEmbedTheCatalogOneTime` (RED: 2 batches before the change, GREEN after) and `twoSessionsOfTwoProfilesEmbedTheCatalogTwoTimes` (passes before and after; it guards against a share across two profiles over one container). Seam: `RecordingEmbeddingContainer` through `StubModelLoader.makeEmbeddingContainer`, `ToolCatalog.sessionSurface`, one `searchTools` call per surface.

    Problem 1 (found by the full `swift test`): HotResumeTests `theReplayAnnouncesTheChildBeforeItsHistory` and `theReplayHoldsTheHistoryOfTheChildBeforeTheResponse` fail with `history -> nil`.
    - With the change: 3 of 9 suite runs failed; suite time 1.0 to 3.1 s.
    - With ProfileEmbedding.swift at HEAD (same pin): 0 of 7 runs failed; suite time 0.66 to 0.89 s.
    - Each failing test passes alone. The fixture `openPrompt` waits for any update of the child, not for the child text, so the test has a latent race. The change makes the race visible.
    - Fact that is relevant to the design: `RoutedModel` holds `residencyHolds`, one `ModelHold` for each slot of the resolve (standard, flash, embedding). The cache keeps the `ProfileEmbedding`, thus the `RoutedModel`, thus the residency of the whole profile, for up to 8 slots after the sessions end. In production, after a profile change, the old profile's LLMs stay resident until 8 newer slots push the slot out. The card says that the retention is safe for the identity. It does not say that the retention keeps the models loaded. The exact cause of the slowdown in the tests is not proven (each test router has its own `ModelPool`).

    Problem 2: `twoSessionsOfOneProfileEmbedTheCatalogOneTime` failed in the full parallel run with 2 batches (test time 65 s). `SearchIndexCache.shared` is process-wide with capacity 8. Now each session of the suite puts a slot in it, and other tests pushed the slot out between the two mounts. A possible correction: mount the two sessions with one registry, back to back, through `registry.makeSessionToolsAndStaging(selection:embedder:)` (the pattern of RunToolSelectionTests). That does not go through `sessionSurface`.

    A person must decide:
    (a) Accept the retention of the full residency, and correct the race in the HotResumeTests fixture (wait for the child text) and the seam of the new test. That is work outside the card.
    (b) Change the identity so that the cache does not keep the residency: for example, Multitool keeps the embedder weakly, or drops a slot when the embedder goes away (a change in a sibling repository; not allowed in this step).
    (c) Another design.
  timestamp: 2026-11-13T05:02:11.858638+00:00
- actor: claude-code
  id: 01m79mhwe2w7e59x70a797bmfp
  text: |-
    ### implement — stuck
    - evidence: pin FoundationModelsMultitool abca4236 -> 9d46b0fa (root and IntegrationTests, no other package moved); files Sources/FoundationModelsACPAgent/Tools/ProfileEmbedding.swift, Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift; targeted `swift test --filter ToolCatalogTests/(twoSessions|theSessionSurfaceHandsTheProfileEmbedder)` 3/3 pass; full `swift test` 2044 tests, 3 failures (2 HotResumeTests, 1 twoSessionsOfOneProfileEmbedTheCatalogOneTime) + 1 known issue, zero compiler warnings; HotResumeTests 3/9 runs fail with the change, 0/7 without. IntegrationTests build not run (stopped before it).
    - next: a person picks option (a), (b) or (c) of the blocker comment.
  timestamp: 2026-11-13T05:02:15.490306+00:00
- actor: claude-code
  id: 01m79n0bpwacfm0rsfqmwdk5kn
  text: |-
    Multitool ^zv7da2 (01M79MTJHVJJDZBEZ6ZHZV7DA2, step1), commit 6c0e3de5 in review, not on main yet. The API CHANGES from the stash:
    - `public protocol IdentifiedEmbedding: PooledEmbedding { var embeddingOwner: any AnyObject & Sendable { get } }`. `embeddingIdentity` is removed. ProfileEmbedding: `var embeddingOwner: any AnyObject & Sendable { embedder }` (the RoutedModel). Change the stashed code to this.
    - Each embed slot holds only weak references (owner, embedder, SharedCatalogEmbedding). The searchers of each session keep the shared embed. When the last session ends, the model goes and the slot drops. Embed slots have no capacity. Thus two sessions share one embed only while at least one is open.
    - Test seam (public): `SearchIndexCache(capacity:)`, `cache.builds`, `cache.sharedEmbeddings`, `cache.liveSharedEmbeddings`, and `registry.makeSessionToolsAndStaging(selection:embedder:sampleModel:indexCache:)`. The test gives its own cache, composes two sessions with one RoutedModel while the first is open, checks `sharedEmbeddings == 1`, then ends both and checks `liveSharedEmbeddings == 0` (the model is released).
    Next run: restore stash@{0} ("wpsm1jx IdentifiedEmbedding and tests"), bump only the Multitool pin to the main commit of ^zv7da2, change to embeddingOwner, and replace the process-wide-cache test with the seam test.
  timestamp: 2026-11-13T05:10:09.884234+00:00
- actor: claude-code
  id: 01m79ndtjspkg71s64htvvasfp
  text: 'Multitool ^hzv7da2 (correct id; 01M79MTJHVJJDZBEZ6ZHZV7DA2) is on main: e2455429 (commits 6c0e3de5, 66ef5975; 2905 tests pass; review clean). The shape is as in the comment above, with one change: only an IdentifiedEmbedding embedder shares its embed between sessions; a class embedder that does not conform shares only inside one bundle. This card is no longer blocked. Bump only the Multitool pin to e2455429 or later.'
  timestamp: 2026-11-13T05:17:31.097929+00:00
- actor: claude-code
  id: 01m79ps2bbmmqh5e7631ss5enm
  text: |-
    Run 2 (after ^hzv7da2):
    - `git stash pop` of stash@{0} applied cleanly (ProfileEmbedding.swift, ToolCatalogTests.swift).
    - `swift package update FoundationModelsMultitool` (root and IntegrationTests): Multitool 9d46b0fa -> e2455429. No other package moved (diff of both Package.resolved files shows one line each).
    - Multitool e2455429: the shared embed is made when the bundle mounts (`RegistryBundle.SearchSource.init`), not at the first search. Thus `cache.sharedEmbeddings` counts the mounts that did not share, and a test needs no search call.
    - The stashed `embeddingIdentity` does not compile against e2455429. For RED, ProfileEmbedding.swift went back to HEAD; the conformance was then written again with `embeddingOwner`.
    - New seam tests (own `SearchIndexCache(capacity: 1)`, one `ToolCatalog.makeRegistry`, two `makeSessionToolsAndStaging(selection:embedder:sampleModel:indexCache:)` mounts over one RoutedModel): RED before the conformance gave `sharedEmbeddings -> 2` and live embeds `[0, 0]`; GREEN after it gives 1 and `[1, 0]`.
    - The first session must stay alive while the second mounts (`withExtendedLifetime`): Swift can release an unused local before the next statement, and then the cache has no live embed to share.
  timestamp: 2026-11-13T05:41:08.075561+00:00
- actor: claude-code
  id: 01m79pwtd5zj7y5s3hkmn1d76s
  text: |-
    ### implement — changed
    - evidence: pin FoundationModelsMultitool 9d46b0fa -> e2455429 (root and IntegrationTests Package.resolved; gitignored; no other package moved). Files: Sources/FoundationModelsACPAgent/Tools/ProfileEmbedding.swift (conforms to IdentifiedEmbedding, `var embeddingOwner: any AnyObject & Sendable { embedder }`, no `embeddingIdentity`; the doc comment says the cache holds the owner weakly, so a released profile frees its models, and one RoutedModel cannot change its model), Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift (the process-wide-cache test is replaced by `twoOpenSessionsOfOneProfileShareOneCatalogEmbed` and `theCacheKeepsNoCatalogEmbedAfterTheSessionsEnd` over the private `SharedEmbedFixture` with an own `SearchIndexCache(capacity: 1)`; `twoSessionsOfTwoProfilesEmbedTheCatalogTwoTimes` is kept; shared helpers `makeEmbeddingContext`, `catalogTexts`, `searchOnce` from the stash). RED: `sharedEmbeddings -> 2`, live embeds `[0, 0]`. GREEN: 2/2 pass. Full `timeout 900 swift test`: 2054 tests in 223 suites pass, 0 failures, 1 known issue (the deliberate one in HarnessSmokeTests); HotResumeTests suite passes. `swift build --build-tests --package-path IntegrationTests`: build complete. Zero compiler warnings; the only "warning:" line is the SwiftPM "missing creator for mutated node" line for the mlx-swift_Cmlx bundle (there before, task ^tvjz12j).
    - notes: the earlier blocker (retention of the residency, flaky HotResumeTests, eviction from the process-wide cache) is gone: Multitool e2455429 holds the owner weakly, and the new tests use an own cache.
    - next: /review. Task stays in doing.
  timestamp: 2026-11-13T05:43:11.013524+00:00
position_column: doing
position_ordinal: '80'
title: ProfileEmbedding conforms to IdentifiedEmbedding, so sessions of one profile share one catalog embed
---
## What
Request of foundationmodelsmultitool-2a and testudoapp-75 (2026-11-12; TestudoApp ^qa2eddw, Multitool ^d84hmxw). Multitool main 9d46b0fa adds `public protocol IdentifiedEmbedding: PooledEmbedding { var embeddingIdentity: ObjectIdentifier { get } }`. `SearchIndexCache` keeps one `SharedCatalogEmbedding` for each catalog and embedder identity. ToolCatalog makes a new `ProfileEmbedding` struct for each session (`ToolCatalog.swift` ~443), and a struct has no identity, so today each `session/new` embeds the whole catalog again.

1. Move only the FoundationModelsMultitool pin to 9d46b0fa or later (root and IntegrationTests). If it needs another family package, move it too and say which.
2. `Sources/FoundationModelsACPAgent/Tools/ProfileEmbedding.swift`: conform to `IdentifiedEmbedding` with `var embeddingIdentity: ObjectIdentifier { ObjectIdentifier(embedder) }`. `RoutedEmbedder` is `RoutedModel`, a final class with `let chosen` and `let container`, so one `RoutedModel` always gives the same vectors; a profile change makes a new `RoutedModel`. The cache keeps the `ProfileEmbedding` and thus the `RoutedModel` alive, so the identifier is not reused. Write this in the doc comment.

## Acceptance Criteria
- [x] Two sessions of the same profile embed the catalog one time (the embedder gets the catalog batch one time).
- [x] Two sessions of two profiles (two embedders) embed it two times.

## Tests
- [x] A test that composes two sessions with the same profile (a counting stub embedder) and checks one catalog embed; and one with two profiles that checks two. Write it first and see it fail.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1
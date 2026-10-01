---
comments:
- actor: claude-code
  id: 01m3vsj3xfjnjj26135ms5hgqt
  text: |-
    Research (pins: Ranker 39e3717, CodeContext 0220e9b, Multitool d2816ca, Extras c5ca65a):
    - `SelectionConfig(model:)` now takes `@Sendable (String) async throws -> any AgentSession`. `OwnedSelectionSession.factory(makingEach:)` gives a sync, non-throwing closure. `makeSearchSelection` compiles only because Swift converts a sync closure to an async throwing closure. Thus the code compiles by accident, not by the card.
    - Skills (`SkillsTool.make(registry:session:)`) still takes a sync factory `(SelectionSessionRequest) -> any AgentSession`. Thus the skills call must keep a sync factory. Plan: add an async throwing overload of `factory(makingEach:)` for the search tier, and keep the sync one for skills.
    - No ACPAgent test double conforms to the Ranker/CodeContext `TextEmbedding`. `RecordingEmbeddingContainer`, `NeverAnsweringEmbeddingContainer` and `StubEmbeddingContainer` conform to the Router `LoadedEmbeddingContainer`, which refines the Extras `PooledEmbedding`. `PooledEmbedding` still requires `dimension` at Extras c5ca65a. Thus their `dimension` must stay, or they do not compile. Only `ProfileTextEmbedding` loses `dimension`.
    - The failing test `theSessionSurfaceHandsTheProfileEmbedderToSearchTools`: the two `["vector length probe"]` batches come from two `CodeContext` instances. The test calls `makeRegistry` one time for the catalog blocks, and `sessionSurface` calls it again. `MeasuredEmbedder` embeds the probe one time for each context. Thus this is one probe for each context, not a double-probe bug. No upstream note is necessary.
  timestamp: 2026-10-01T13:13:18.511295+00:00
- actor: claude-code
  id: 01m3vszsn939r9rnm9bekw8d0g
  text: |-
    Implementation:
    - `OwnedSelectionSession.factory(makingEach:)` has a new async throwing overload. It takes `(Request) async throws -> any RoutedSession` and gives `(Request) async throws -> any AgentSession`, the type of `SelectionConfig(model:)`. The sync overload stays for `SkillsTool.make(registry:session:)`, which still takes a sync factory. The compiler picks the overload from the context type, so no call is ambiguous.
    - `ToolCatalog.makeSearchSelection(makingEach:)` is the new seam. It takes a `GuidedSessionMaker` (`(Grammar, String) async throws -> any RoutedSession`). `makeSearchSelection(profile:)` calls it with the flash slot.
    - `ProfileTextEmbedding` has no `dimension` now.
    - New `Tests/FoundationModelsACPAgentTests/SearchSelectionTests.swift`. Each test runs a real `SelectionTier` search: (1) the tier awaits an async maker, and the maker gets the id grammar of the catalog; (2) an error of the maker comes out of the search.
    - `theSessionSurfaceHandsTheProfileEmbedderToSearchTools`: two causes made it fail. (a) The probe batches: the test turns the `codeContext:` section off, because the code context is a different consumer of the embedder and its batches come in at no known time. (b) Multitool d2816ca embeds `renderEmbeddedText(from:)` (the summary block), not `block`. The test now expects `entry.renderEmbeddedText(from: entry.block)`.

    Discoveries:
    - Probe count proof: a scratch test (deleted after the run) opened one `CodeContext` over one Python file and stopped it. The batches were `[["vector length probe"], [<the chunk>]]`: one probe for one context. Thus there is no double-probe bug. The two probes in the old failure came from two `makeRegistry` calls in that test.
    - `SelectionTier.idEnumSchema(ids:)` uses `JSONSerialization` with no `.sortedKeys`, so the key order of the schema text changes between calls. A test must compare the decoded JSON, not the text. (The first full run failed on this.)

    Not done: see `## Blocker` in the description. The three test doubles keep `dimension`, because the Extras `PooledEmbedding` requires it. Push and CI are left to the commit step, as the dispatching agent said.
  timestamp: 2026-10-01T13:20:46.761168+00:00
- actor: claude-code
  id: 01m3vszyr75nv904wagyxgg3ek
  text: |-
    ### implement — stuck
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Tools/OwnedSelectionSession.swift, Sources/FoundationModelsACPAgent/Tools/ProfileTextEmbedding.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift, Tests/FoundationModelsACPAgentTests/SearchSelectionTests.swift (new). `swift test`: 670 tests in 77 suites passed (668 + 2 new), 1 known issue, 0 compiler warnings. `swift build --build-tests` in IntegrationTests/: Build complete, 0 warnings.
    - gap: the card item "RecordingEmbedding.swift and other doubles: remove `dimension`" cannot compile, because the Extras `PooledEmbedding` (c5ca65a) requires `dimension` of each `LoadedEmbeddingContainer`. A person must drop this item or add upstream work. Push and CI are left to the commit step.
    - next: a person decides the `dimension` item; then /review.
  timestamp: 2026-10-01T13:20:51.975133+00:00
position_column: doing
position_ordinal: '8380'
title: Adopt the async selection factory and the TextEmbedding without dimension
---
**Wait for:** FoundationModelsRanker tasks 01M3QMD9KJ8T723R02085BEFYY ("Remove dimension from TextEmbedding") and 01M3QMD9X40XA640Z9CXCREQAM ("Async session factory…") on the Ranker board: done and pushed.

## What
- `Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` (~lines 373 and 415): `OwnedSelectionSession.factory(makingEach:)` gives the async throwing factory type that `SelectionConfig(model:)` and `Searcher(session:)` now take.
- `Sources/FoundationModelsACPAgent/Tools/ProfileTextEmbedding.swift`: remove `dimension`.
- `Tests/FoundationModelsACPAgentTestSupport/RecordingEmbedding.swift` and other doubles: remove `dimension`.
- `swift package update`, confirm the new Ranker revision; push to `origin main` when green.

## Acceptance Criteria
- [x] ACPAgent builds; `ToolCatalog` search selection works with the async factory.
- [x] No ACPAgent source reads an embedder `dimension`.
- [ ] CI is green on the pushed commit.

## Tests
- [x] `Tests/` for `ToolCatalog.makeSearchSelection`: an async factory is awaited; a throwing factory surfaces its error.
- [x] `swift test` passes.

## Decision (2026-10-01, orchestrator)
- [x] The "remove `dimension` from the doubles" item applies to the doubles of the Ranker `TextEmbedding` only. No such double has `dimension` now. `RecordingEmbeddingContainer`, `StubEmbeddingContainer` (EchoModel.swift) and `NeverAnsweringEmbeddingContainer` (ToolCatalogTests.swift) conform to the Router `LoadedEmbeddingContainer`, which refines the Extras `PooledEmbedder`. Extras `PooledEmbedder.swift:8` requires `var dimension: Int`, so these three doubles keep it. This is correct, not a blocker.
- [ ] Push to `origin main` and the CI check: done after the review is clean.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool
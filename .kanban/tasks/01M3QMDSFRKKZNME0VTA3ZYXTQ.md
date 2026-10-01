---
position_column: todo
position_ordinal: '9780'
title: Adopt the async selection factory and the TextEmbedding without dimension
---
**Wait for:** FoundationModelsRanker tasks 01M3QMD9KJ8T723R02085BEFYY ("Remove dimension from TextEmbedding") and 01M3QMD9X40XA640Z9CXCREQAM ("Async session factory…") on the Ranker board: done and pushed.

## What
- `Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` (~lines 373 and 415): `OwnedSelectionSession.factory(makingEach:)` gives the async throwing factory type that `SelectionConfig(model:)` and `Searcher(session:)` now take.
- `Sources/FoundationModelsACPAgent/Tools/ProfileTextEmbedding.swift`: remove `dimension`.
- `Tests/FoundationModelsACPAgentTestSupport/RecordingEmbedding.swift` and other doubles: remove `dimension`.
- `swift package update`, confirm the new Ranker revision; push to `origin main` when green.

## Acceptance Criteria
- [ ] ACPAgent builds; `ToolCatalog` search selection works with the async factory.
- [ ] No ACPAgent source reads an embedder `dimension`.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `Tests/` for `ToolCatalog.makeSearchSelection`: an async factory is awaited; a throwing factory surfaces its error.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool
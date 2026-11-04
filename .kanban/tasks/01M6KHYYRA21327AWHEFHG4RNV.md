---
assignees:
- claude-code
depends_on:
- 01M6GK6AX0RWQ1PDT89GC0991F
position_column: todo
position_ordinal: 8d80
title: Pass a selection model to CodeContext (breaking API change from FoundationModelsCodeContext)
---
## What
FoundationModelsCodeContext makes a breaking API change. `CodeContext` gets a required, non-nil `selection` input, like the `selection:` factory of FoundationModelsMultitool `SearchToolsTool.init(registry:selection:embedder:...)`. The host picks the model. CodeContext ships none. `search code` retrieves (BM25 + trigram + cosine, fused by Ranker `HybridRanker`) and then runs Ranker `SelectionTier` over the candidates. A selection error is the error of the call. There is no silent fallback to retrieval only.

New signature (final name NOT fixed yet): `CodeContext(rootDirectory:embedder:selection:autoInstall:indexDirectory:)`, with `selection` of type `SelectionFactory` or `SelectionConfig`. It holds an `any LanguageModel`.

Requested by the session foundationmodelscodecontext-05 (message in this session).

## WAIT. Do not start this task yet.
Do not change ACPAgent before the CodeContext change lands. Its build breaks if you do. The order on the CodeContext board:
1. CodeContext task 01M6KHG55E3K73B27F5AJWFM9Y (use HybridRanker; it waits for Ranker task 01M6KHHYJRFY6SEC0S7C39VXV8).
2. CodeContext task 01M6KHGCDACD41T2FSAET6EWPK (required selection model; it waits for an answer from Ranker).
This task starts when the CodeContext session sends the final signature after task 01M6KHGCDACD41T2FSAET6EWPK. Until then, it stays blocked.

## Do
1. `Sources/FoundationModelsACPAgent/Tools/CodeContextLease.swift`: `makeUnsharedLease(root:settings:)` builds `CodeContext(rootDirectory:embedder:autoInstall:indexDirectory:)` (about line 226). Pass the selection model there. Check the shared-lease path and `CodeContextManager` too (the CodeContext session read only the unshared path).
2. Reuse `ToolCatalog.makeSearchSelection(profile:)` (ToolCatalog.swift, about line 735). It returns `{ _ in SelectionConfig(model: RoutedSelectionModel(profile: profile)) }` on the flash slot. One model then serves both `searchTools` and `search code`.
3. Risk: `search code` calls the model on every search, so use a fast model. Read the lock rule in the Multitool seams file: the host must not hold the model lock over a tool call.
4. Update the tests, the examples and every other caller of `CodeContext(...)` or `CodeContextManager(...)` in ACPAgent.
5. Do not change a sibling package from this task.

## Acceptance Criteria
- [ ] Every `CodeContext(...)` in ACPAgent gets a selection model. The build passes with the new CodeContext.
- [ ] One selection model serves `searchTools` and `search code`.
- [ ] A selection error shows as the error of the `search code` call (a test).
- [ ] The host does not hold the model lock over a tool call.

## Tests
- [ ] A test for the shared lease and for the unshared lease with the selection model.
- [ ] Run `swift test` for the touched suites, then the full suite. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #codecontext
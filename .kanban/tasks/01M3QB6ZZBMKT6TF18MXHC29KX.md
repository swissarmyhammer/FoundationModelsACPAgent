---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3qbtkgzyvjgr7qptx21xpcg
  text: |-
    Research: the pinned Multitool (.build/checkouts/FoundationModelsMultitool, MultiTool.swift) has `makeSessionTools(selection:embedder:sampleSession:) throws -> [any Tool]` and `makeSessionToolsAndStaging(selection:embedder:sampleSession:) throws -> (tools:, staging:)`. `selection` is a `SearchToolsTool.SelectionFactory?`, `embedder` is `(any TextEmbedding)? = nil`, `sampleSession` is `SearchToolsTool.SessionFactory? = nil`. `ToolCatalog.sessionSurface` passes `makeSearchSelection(profile:)` (guided sessions on `profile.flash`) and `ProfileTextEmbedding(embedder: profile.embedding)`, and does not pass `sampleSession`. A search of plan.md, cli-plan.md, README.md and Sources found one more stale mention: the doc comment of `MCPComposition.startSurfaceRefresher` named `makeSessionToolsAndStaging(selection:embedder:)` with no `sampleSession:`. The word "librarian" in other doc comments names the flash selection model as a concept, not a parameter, so it stays.

    Implementation: plan.md §11.1 now names the current call, shows the signature, and gives the meaning of each parameter and the value the catalog passes. The unclear sentence about a wait is rewritten: a tool body inside a submission holds the model and blocks each other session on the same model; so there is no `wait` tool; a run that does not settle in its inline grace goes to the background and comes back as mail that starts a new submission (§8.0). MCPComposition.swift doc comment is corrected.
  timestamp: 2026-09-29T19:56:18.847846+00:00
- actor: claude-code
  id: 01m3qbtnm1f37638tcrfhhn3cc
  text: |-
    ### implement — changed
    - evidence: plan.md (§11.1), Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift (doc comment only). `swift test`: 615 tests in 70 suites passed (1 known issue, from before this change), zero compiler warnings. `swift build` after the last plan.md reflow: complete. `rg -n "librarian:|sampleGenerator" plan.md` gives no match.
    - next: /review
  timestamp: 2026-09-29T19:56:20.993805+00:00
- actor: claude-code
  id: 01m3qc37w1rx33e1k5zf9f1atx
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (861b330). 0 findings, 0 confirmed, 0 refuted, 7 validator runs attempted, 0 failed. The engine reviewed 1 file. No validator matches plan.md, so the engine did not review it. The .reviewignore file excludes the 4 .kanban files.
    - next: none. The task is in done.
  timestamp: 2026-09-29T20:01:01.825856+00:00
- actor: claude-code
  id: 01m3qc3jrtb16d8whhsb922smq
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — plan.md §11.1, MCPComposition.swift (doc comment only)
    - test: green — swift test 615 tests pass
    - commit: 861b330
    - review: clean — zero findings; task moved to done. The orchestrator read the plan.md diff by hand (no Markdown validator) and checked the acceptance items: the rg finds no stale signature.
  timestamp: 2026-09-29T20:01:12.986833+00:00
position_column: done
position_ordinal: fa80
title: plan.md §11.1 names a stale `makeSessionTools(librarian:sampleGenerator:)` signature
---
## Why

plan.md §11.1 says `MultiTool.Registry.makeSessionTools(librarian:sampleGenerator:)` and `makeSessionTools(librarian: RoutedLLM?, sampleGenerator: RoutedLLM? = nil) throws -> [any Tool]`. The pinned Multitool has `makeSessionTools(selection:embedder:sampleSession:)` and `makeSessionToolsAndStaging(selection:embedder:sampleSession:)`, and `ToolCatalog.sessionSurface` calls `makeSessionToolsAndStaging`. A reader learns a wrong API.

## What

Rewrite the §11.1 text for the current signatures and for the call that `ToolCatalog` makes. Write in ASD-STE100 Simplified Technical English.

## Acceptance Criteria

- [x] `rg -n "librarian:|sampleGenerator" plan.md` shows no stale signature.
- [x] No code change.

Found by ^f4tye31. #generation-queue
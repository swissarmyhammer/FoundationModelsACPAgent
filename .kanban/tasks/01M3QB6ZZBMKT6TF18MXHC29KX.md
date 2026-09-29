---
assignees:
- claude-code
position_column: todo
position_ordinal: '9880'
title: plan.md §11.1 names a stale `makeSessionTools(librarian:sampleGenerator:)` signature
---
## Why

plan.md §11.1 says `MultiTool.Registry.makeSessionTools(librarian:sampleGenerator:)` and `makeSessionTools(librarian: RoutedLLM?, sampleGenerator: RoutedLLM? = nil) throws -> [any Tool]`. The pinned Multitool has `makeSessionTools(selection:embedder:sampleSession:)` and `makeSessionToolsAndStaging(selection:embedder:sampleSession:)`, and `ToolCatalog.sessionSurface` calls `makeSessionToolsAndStaging`. A reader learns a wrong API.

## What

Rewrite the §11.1 text for the current signatures and for the call that `ToolCatalog` makes. Write in ASD-STE100 Simplified Technical English.

## Acceptance Criteria

- [ ] `rg -n "librarian:|sampleGenerator" plan.md` shows no stale signature.
- [ ] No code change.

Found by ^f4tye31. #generation-queue
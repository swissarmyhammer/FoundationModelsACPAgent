---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Declare package dependencies, targets, and test target in Package.swift
---
## What
Turn the dependency-free manifest into the real one (plan.md §1). In `Package.swift`, declare family dependencies following the sibling convention (`.package(url: "git@github.com:swissarmyhammer/<Name>.git", branch: "main")`, as in FoundationModelsMultitool):
- `FoundationModelsACP` (the wire), `FoundationModelsRouter` (the runtime), `FoundationModelsExtras`, `FoundationModelsMultitool` (the consolidated tool surface — its capability modules supply files, shell, and mcp).
- Do NOT add separate FileTool/Shelltool/MCP/Skills packages — those dissolve into Multitool (plan.md §1, Multitool eventplan). The skills and agents capabilities are plan-only upstream (§11.3); they arrive inside Multitool, with no new manifest line.

Add these products to the `FoundationModelsACPAgent` target's dependencies, and add a `FoundationModelsACPAgentTests` test target. Keep `.macOS(.v26)` and swift-tools-version 6.2.

- [ ] Family dependencies declared per sibling convention
- [ ] Test target `Tests/FoundationModelsACPAgentTests/` added
- [ ] Import smoke test added

## Acceptance Criteria
- [ ] `swift build` succeeds
- [ ] `swift test` succeeds (smoke suite)
- [ ] All four dependency modules are importable from the library target

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ImportSmokeTests.swift`: imports FoundationModelsACP, FoundationModelsRouter, FoundationModelsExtras, FoundationModelsMultitool and references one public type from each
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Declare package dependencies, targets, and test target in Package.swift
---
## What
Turn the dependency-free manifest into the real one (plan.md §1). In `Package.swift`, declare family dependencies following the sibling convention (`.package(url: "git@github.com:swissarmyhammer/<Name>.git", branch: "main")`, as in FoundationModelsMCP):
- `FoundationModelsACP` (the wire), `FoundationModelsRouter` (the runtime), `FoundationModelsExtras`, `FoundationModelsFileTool`, `FoundationModelsShelltool`, `FoundationModelsMCP`.
- Do NOT add `FoundationModelsSkills` yet — its command half is plan-only upstream (§11.3); it gets one manifest line when it ships.

Add these products to the `FoundationModelsACPAgent` target's dependencies, and add a `FoundationModelsACPAgentTests` test target. Keep `.macOS(.v26)` and swift-tools-version 6.2.

- [ ] Family dependencies declared per sibling convention
- [ ] Test target `Tests/FoundationModelsACPAgentTests/` added
- [ ] Import smoke test added

## Acceptance Criteria
- [ ] `swift build` succeeds
- [ ] `swift test` succeeds (smoke suite)
- [ ] All six dependency modules are importable from the library target

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ImportSmokeTests.swift`: imports FoundationModelsACP, FoundationModelsRouter, FoundationModelsExtras, FoundationModelsFileTool, FoundationModelsShelltool, FoundationModelsMCP and references one public type from each
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
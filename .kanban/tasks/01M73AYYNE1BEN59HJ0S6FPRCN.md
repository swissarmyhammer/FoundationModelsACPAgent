---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: 'ToolCatalogTests: theSkillsRegistryWatchesForCommandUpdates asserts a value that is always true'
---
Found during ^bwgmkc0. Skills (SK-6a) makes `SkillsRegistry.commandUpdates` never nil, whatever `watch` is. Thus `#expect(registry.commandUpdates != nil)` in `Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift` (`theSkillsRegistryWatchesForCommandUpdates`) cannot fail, and it does not prove that `ToolCatalog.makeSkillsSource` gives `watch: true`.

## Acceptance Criteria
- [ ] The test fails when `makeSkillsSource` gives `watch: false`. For example: write a skill file after the build, and confirm that `onReload` (or `commandUpdates`) gives a rebuild that contains the new skill.
- [ ] `swift test` passes with no warnings.
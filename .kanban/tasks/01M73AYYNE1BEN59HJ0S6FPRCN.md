---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m78hpa5xqg81pb45atngkbc2
  text: |-
    Research: `SkillsRegistry.commandUpdates` (FoundationModelsSkills, SkillsRegistry+SlashCommands.swift) is a bridge over `onReload` and is never nil. `onReload` publishes on each rebuild that changes the catalog, from `reload()`, from the watcher (only with `watch: true`), or from a marketplace update. The context of ToolCatalogTests uses `AgentConfiguration.withoutMarketplaces`, thus only the watcher can give a rebuild for a file write. The project layer of the skills stack is `<cwd>/.skills`, and the watcher sees that folder also when it was not there at the start (the same fact that AgentCatalogWatchTests uses).

    Change: the test `theSkillsRegistryWatchesForCommandUpdates` is replaced by `theSkillsSourcePublishesTheCommandOfANewSkill`. It subscribes to `commandUpdates` before the write, writes `<cwd>/.skills/late-skill/SKILL.md` with `writeSkillFixture`, and waits on the command sets until one has `late-skill`. It uses no clock; `.timeLimit(.minutes(1))` bounds the wait.

    Proof of failure: with `watch: false` in the no-marketplace branch of `ToolCatalog.makeSkillsSource(context:marketplaces:sessionAgent:)`, the test failed: "Time limit was exceeded: 60.000 seconds" and "Expectation failed: names.contains(Self.lateSkillID)" with `names → []`. The change was reverted (`git checkout` of ToolCatalog.swift), and the test passed after 0.230 seconds.
  timestamp: 2026-11-12T18:53:00.477927+00:00
- actor: claude-code
  id: 01m78hr62k73dpt6hkcqfcrj2x
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift (the test `theSkillsRegistryWatchesForCommandUpdates` is replaced by `theSkillsSourcePublishesTheCommandOfANewSkill`, with the constants `lateSkillID`, `lateSkillMarkdown`, `skillsProjectLayerName`). RED: with `watch: false` in `makeSkillsSource`, the test failed (time limit, `names → []`); the change was reverted. GREEN: the test passed in 0.230 s. Full `swift test`: 2014 tests in 220 suites passed, 0 failures, 1 known issue that was there before (HarnessSmokeTests `withKnownIssue`), 0 compiler warnings (the one `warning:` line is the SwiftPM build note "missing creator for mutated node" of the mlx bundle).
    - limit: the test covers the no-marketplace branch of `makeSkillsSource(context:marketplaces:sessionAgent:)`, because the context uses `AgentConfiguration.withoutMarketplaces`. The marketplace branch also gives `watch: true`, but a test of it needs a marketplace store.
    - next: review
  timestamp: 2026-11-12T18:54:01.811537+00:00
position_column: doing
position_ordinal: '8280'
title: 'ToolCatalogTests: theSkillsRegistryWatchesForCommandUpdates asserts a value that is always true'
---
Found during ^bwgmkc0. Skills (SK-6a) makes `SkillsRegistry.commandUpdates` never nil, whatever `watch` is. Thus `#expect(registry.commandUpdates != nil)` in `Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift` (`theSkillsRegistryWatchesForCommandUpdates`) cannot fail, and it does not prove that `ToolCatalog.makeSkillsSource` gives `watch: true`.

## Acceptance Criteria
- [x] The test fails when `makeSkillsSource` gives `watch: false`. For example: write a skill file after the build, and confirm that `onReload` (or `commandUpdates`) gives a rebuild that contains the new skill.
- [x] `swift test` passes with no warnings.
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f7pxavx7d6zkce0zwz3xw0
  text: 'RED (tests only, before any production change): `swift test --filter ''SettingsGraphTests|SettingsToolTests|SettingsToolSessionTests|ToolCatalogTests''` -> 69 tests in 4 suites, 24 tests failed with 57 issues. Every failure is GRAPHQL_VALIDATION_FAILED: `Field "set" on type "Mutation" does not have argument "input". The arguments of Mutation.set are: keyPath, value, level, cwd.` (and the same for `clear`). The current alias table rewrites `updateSetting` -> `set`, and `set` has only the flat arguments, so `updateSetting(input:)`/`clearSetting(input:)` do not exist yet. Failing tests include theOldSetAndClearNamesGiveTheSameResult, aMutationAliasReachesTheMutation, aSetOnTheUserLevelWorks, aClearOnTheSessionLevelRestoresTheUserValue, eachLevelChangesThroughTheTool, aRunCodeCallChangesTheSessionLevelOfTheCwd, aSettingsCallThroughTheRegistryWritesTheSessionLevelOfTheSession. Test callers updated in SettingsToolTests, SettingsToolSessionTests, ToolCatalogTests to the input form and the `updateSetting`/`clearSetting` response keys.'
  timestamp: 2026-10-21T12:41:51.707250+00:00
- actor: claude-code
  id: 01m5f7z8m1mrfy7anjhr3ct1bz
  text: |-
    ### implement — changed
    - evidence: commit c5ab74bf54db52fa1fa18426d1ca02558f7f8f78 on main (not pushed). RED: settings suites 69 tests / 4 suites, 24 tests failed with 57 issues, each GRAPHQL_VALIDATION_FAILED "Field \"set\" on type \"Mutation\" does not have argument \"input\"" (updateSetting/clearSetting did not exist; the old table rewrote updateSetting -> set). GREEN: `swift test --filter 'SettingsGraphTests|SettingsToolTests|SettingsToolSessionTests|ToolCatalogTests'` 69 tests in 4 suites passed. Full `swift test`: 1177 tests in 127 suites passed with 1 known issue (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps).
    - changes: SettingsGraphSchema.swift adds input objects UpdateSettingInput (keyPath, value JSON!, level, cwd) and ClearSettingInput (keyPath, level, cwd), argument structs hold `input`, mutations `updateSetting(input:)` / `clearSetting(input:)` give the changed Setting; resolvers renamed set->updateSetting, clear->clearSetting (cwd resolution and read-after-change warning unchanged). SettingsGraph.swift alias table: `updateSetting: [set, setSetting, update]`, `clearSetting: [clear, unset, remove, removeSetting]` (update/updateSetting no longer map to set); docs updated. SettingsTool.swift description names `updateSetting(input: {keyPath:, value:, level:})` and `clearSetting(input: {keyPath:, level:})`. Tests/Fixtures/settings.graphql recorded with GRAPHQL_GOLDEN_RECORD=1 on the golden test only (golden test unchanged). Test callers: SettingsToolTests, SettingsToolSessionTests, ToolCatalogTests now use the input form and the updateSetting/clearSetting response keys.
    - note: rule 7 (EXTRAS-9) requires exactly `verbNoun(input: VerbNounInput!)`, so the flat-argument form `set(keyPath:, value:, level:)` cannot stay. The aliases `set`/`clear` are NAME aliases only: an old caller keeps working only with the input form (`set(input: {...})`), which theOldSetAndClearNamesGiveTheSameResult proves, with the rewrite in extensions.rewrites. A caller that still sends flat arguments gets GRAPHQL_VALIDATION_FAILED. TestudoApp has no settings mutation caller (checked by the lead).
    - next: /review
  timestamp: 2026-10-21T12:46:25.409117+00:00
- actor: claude-code
  id: 01m5f80df1x8w3qkbmvr1kevyv
  text: |-
    ### done
    - sha c5ab74b (feature) + 0b9d945 (record). RED: 24 of 69 tests in the 4 settings suites failed with GRAPHQL_VALIDATION_FAILED (no `input` argument). GREEN: the 69 tests pass; full `swift test` 1177 tests / 127 suites passed, 1 known issue. Conformance with the alias probe is empty.
  timestamp: 2026-10-21T12:47:03.137165+00:00
position_column: done
position_ordinal: fffd80
title: 'EXTRAS-9 settings: updateSetting(input:) and clearSetting(input:), with set and clear as aliases'
---
From the Multitool session, which coordinates the GraphQL endpoint conventions (EXTRAS-9 rule 7, D115, status proposed; spec in TestudoApp/features/packages/foundationmodels-extras.md). SettingsGraph is the reference endpoint that the others copy.

## Today
`SettingsGraphSchema.swift:524` and `:532` declare `Field("set", ...)` and `Field("clear", ...)`. `SettingsGraph.swift:45` maps `"set": ["setSetting", "update", "updateSetting"]`, so the toolkit's set→update verb synonym clashes with `set`.

## Change
- Mutations `updateSetting(input: UpdateSettingInput!)` and `clearSetting(input: ClearSettingInput!)`. The result is the changed node (the `Setting`).
- `set` and `clear` stay as aliases through `GraphQLNameRules` (D86), so no caller breaks: SettingsTool, the model, and TestudoApp.
- The alias table no longer maps `update`/`updateSetting` to `set`.
- Update the schema golden file and the descriptions.

## Done when
- A failing test first (TDD): `updateSetting(input:)` and `clearSetting(input:)` work, and the old `set`/`clear` calls give the same result through the aliases.
- `GraphQLEndpointConformance.problems` with the alias probe is still empty, and the full `swift test` passes. #extras-9 #settings
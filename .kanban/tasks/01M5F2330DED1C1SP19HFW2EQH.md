---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f7pxavx7d6zkce0zwz3xw0
  text: 'RED (tests only, before any production change): `swift test --filter ''SettingsGraphTests|SettingsToolTests|SettingsToolSessionTests|ToolCatalogTests''` -> 69 tests in 4 suites, 24 tests failed with 57 issues. Every failure is GRAPHQL_VALIDATION_FAILED: `Field "set" on type "Mutation" does not have argument "input". The arguments of Mutation.set are: keyPath, value, level, cwd.` (and the same for `clear`). The current alias table rewrites `updateSetting` -> `set`, and `set` has only the flat arguments, so `updateSetting(input:)`/`clearSetting(input:)` do not exist yet. Failing tests include theOldSetAndClearNamesGiveTheSameResult, aMutationAliasReachesTheMutation, aSetOnTheUserLevelWorks, aClearOnTheSessionLevelRestoresTheUserValue, eachLevelChangesThroughTheTool, aRunCodeCallChangesTheSessionLevelOfTheCwd, aSettingsCallThroughTheRegistryWritesTheSessionLevelOfTheSession. Test callers updated in SettingsToolTests, SettingsToolSessionTests, ToolCatalogTests to the input form and the `updateSetting`/`clearSetting` response keys.'
  timestamp: 2026-10-21T12:41:51.707250+00:00
position_column: doing
position_ordinal: '8380'
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
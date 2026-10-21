---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
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
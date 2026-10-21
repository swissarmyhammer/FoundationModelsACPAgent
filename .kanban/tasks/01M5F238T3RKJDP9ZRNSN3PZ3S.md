---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'EXTRAS-9 settings: changes(after:) with an opaque cursor, a cursor query, and RESYNC_REQUIRED (blocked on EXTRAS-10 ChangeLog)'
---
From the Multitool session (EXTRAS-9 rev 2, rule 9; D115; status proposed; spec in TestudoApp/features/packages/foundationmodels-extras.md).

BLOCKED: this needs `ChangeLog` and the codes `NOT_FOUND` and `RESYNC_REQUIRED` from EXTRAS-10 in FoundationModelsExtras. EXTRAS-10 has no owner yet. Do not write a copy of ChangeLog here (EXTRAS-9 rule 2).

## Today
`SettingsGraphSchema.swift:423` has `changes(cwd:)`, which calls `SettingsEngine.changes(cwd:)`. The `SettingsChange` event has no cursor and no `at`.

## Change, when EXTRAS-10 is in
- The cursor is opaque: a root query `cursor: String!` and the subscription `changes(after: String)`. ChangeLog has an epoch for each instance. A cursor from before a restart, from another epoch, too old, or after the newest event gives `RESYNC_REQUIRED`. (The reason: an Int seq starts again with the process, and can match new state with no error.)
- `SettingsChange` has `cursor: String!`, `at: DateTime!`, `added: [ID!]!`, `changed: [ID!]!` and `removed: [ID!]!`. For settings, the ids are key paths. `level`, `cwd` and `keyPath` can stay as extra fields.
- `cwd` stays as an extra optional argument of `changes` and `cursor`.
- Make the endpoint and its ChangeLog one time for each settings store, not one time for each SettingsTool copy. Then two tools on the same store give the same cursor.
- SettingsTool refuses a subscription with `SUBSCRIPTION_NOT_IN_TOOL` (rule 10). Check whether it does already.
- When EXTRAS-11 adds the new conformance checks before this card is done, list each failed rule as an exception in `SettingsGraphTests`, with the ID of this card.

## Done when
- A failing test first (TDD), with these cases:
  - A client reads `cursor`, a change happens, and `changes(after: cursor)` gives that change, with its key path in `changed` (or in `added` or `removed`).
  - A cursor of another epoch (a new store instance) gives `RESYNC_REQUIRED`. A cursor that is too old also gives it.
  - Two SettingsTool copies on one store share one cursor sequence.
- The full `swift test` passes.
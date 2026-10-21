---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'EXTRAS-9 settings: changes(after:) with seq and at, a cursor query, and RESYNC_REQUIRED (blocked on EXTRAS-10 ChangeLog)'
---
From the Multitool session (EXTRAS-9 rule 9, D115, status proposed).

BLOCKED: this needs `ChangeLog<Event>` and the codes `NOT_FOUND` and `RESYNC_REQUIRED` from EXTRAS-10 in FoundationModelsExtras. EXTRAS-10 has no owner yet, and no Extras session is running. Do not write a copy of ChangeLog here (EXTRAS-9 rule 2).

## Today
`SettingsGraphSchema.swift:423` has `changes(cwd:)`, which calls `SettingsEngine.changes(cwd:)`. The `SettingsChange` event has no `seq` and no `at`.

## Change, when EXTRAS-10 is in
- The subscription `changes(after: Int)`. Keep `cwd` as an extra argument for the filter.
- `SettingsChange` gains `seq: Int!` and `at: DateTime!`, plus the id of each changed item.
- A root query `cursor: Int!`.
- `RESYNC_REQUIRED` when `after` is older than the buffer.
- SettingsTool refuses a subscription with `SUBSCRIPTION_NOT_IN_TOOL` (rule 10). Check whether it does already.
- When EXTRAS-11 adds the new conformance checks before this card is done, list each failed rule as an exception in `SettingsGraphTests`, with the ID of this card.

## Done when
- A failing test first (TDD): a client reads `cursor`, a change happens, and `changes(after: cursor)` gives that change with the next `seq`. Also: an old `after` gives `RESYNC_REQUIRED`.
- The full `swift test` passes. #extras-9 #settings #blocked-upstream
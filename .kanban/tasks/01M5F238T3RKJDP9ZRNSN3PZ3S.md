---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f3wjknwc67qfqx1z25faca
  text: |-
    ### unblocked: EXTRAS-10 is on FoundationModelsExtras main
    - Code commit f126153, tip 11ffe56. Run `swift package update FoundationModelsExtras` first.
    - API in Sources/FoundationModelsExtras/GraphQL/:
      - `actor ChangeLog<Event>` with `init(capacity: Int = 1024)`, `append(_:)`, `cursor` and `changes(after:where:)`.
      - Each stream element is a `ChangeLogEntry<Event> { cursor: String, at: Date, event }`. `changes(after: nil)` gives only live events. Use `where` for the cwd filter.
      - IDChange.swift has the helpers `ChangedIDs` and `IDChange`. SettingsChange keeps level, cwd and keyPath as extra fields.
      - Codes: `GraphQLToolkitError.notFound(kind:id:)` and `.resyncRequired(reason:)`.
    - Changes in behavior:
      - A subscription stream that throws a coded error now sends one last `{"errors":[…]}` with extensions.code, and then ends normally. Check SettingsGraphTests for a test that expects the old raw throw.
      - A subscriber that is more than `capacity` events behind gets RESYNC_REQUIRED.
    - The description already holds rev 2 (opaque cursor, added/changed/removed).
  timestamp: 2026-10-21T11:35:03.029828+00:00
- actor: claude-code
  id: 01m5f644sdq91gj1t8px8sgtf3
  text: |-
    ### the ID scalar is in (Extras 44c2f54, tip 9c47e10)
    - For the change ids, call `SchemaBuilder.addToolkitIDScalar()` and use `ToolkitID`. Do not add an exception for ^70231sy.
    - EXTRAS-11 (dbf4202) makes SettingsGraphTests fail on rule 7 and rule 9 after the Extras update. In the same change, either land ^hfw2eqh, or pass `exceptions:` (rule 7 removedBy ^hfw2eqh, rule 9 removedBy this card) and `codes:` with each error and warning code of SettingsGraph.
  timestamp: 2026-10-21T12:14:08.173215+00:00
- actor: claude-code
  id: 01m5f9kzwcvnzvgpkc1ggt7p0w
  text: |-
    ### implement: rule 9 for settings (Extras ac1b9f2, Multitool c9f70cd)
    - RED 1 (runtime): `swift test --filter 'SettingsSubscriptionTests|SettingsToolTests/twoToolsOnOneStoreShareOneCursorSequence|SettingsGraphTests/theEndpointConforms'` → 10 tests failed: no `cursor` field (`reply.data?[cursor]` nil), the new `changes(cwd:after:){cursor at added changed removed …}` shape (no `changes` object), and theEndpointConforms with the rule 9 exception removed (7 rule 9 problems).
    - RED 2 (compile): aTooOldCursorGivesResyncRequired needs `SettingsStore(changeCapacity:)` / `SettingsStore.defaultChangeCapacity` → "extra argument 'changeCapacity'".
    - GREEN: the same filter + SettingsStore/SessionSettingsStore suites → 72 tests, only the golden file failed; re-recorded `Tests/Fixtures/settings.graphql` with GRAPHQL_GOLDEN_RECORD=1 on theSchemaMatchesTheGoldenFile only and checked the diff (cursor/at/added/changed/removed on SettingsChange, Query.cursor(cwd:), changes(after:, cwd:)).
    - SettingsTreeDifferenceTests was written after the code (not TDD order). Its first run failed (aNullRootHasNoKey): a whole nested mapping that was added gave its top key, not its leaves. Fixed the code to list the leaves; the removed-section expectation in the other test moved to the leaf for the same rule.
    - Design: the ChangeLog<SettingsLoggedChange> lives in SettingsStore (one per store; a new store = a new epoch). Every SettingsGraph / SettingsTool over a store reads that one log, so two tools share one cursor sequence (twoToolsOnOneStoreShareOneCursorSequence). I did NOT cache one SettingsGraph instance per store: the store owning the graph would make a store → graph → engine → store retain cycle, and the endpoint holds no state of its own besides the store. The schema is still built once per SettingsTool, as before. If one instance is still wanted, the cycle-free way is to build the graph next to the store (RoutedACPAgent) and pass it through CatalogContext. That is a separate card.
    - ids: set of a key with no value on its level → added; set of a key with a value → changed; clear → removed (the key path, dotted). A file reload (keyPath nil) → the leaf key paths that differ between the rendered tree before and after (SettingsTreeDifference); a whole mapping added/removed lists its leaves; a list is one leaf. The re-read after stopWatching() is logged once per forgotten level by `SettingsStore.resumeWatching(cwd:)`, with the difference from the tree before the stop (empty when nothing changed). It goes to the log only, not to the legacy `changes()` streams.
    - `cursor(cwd:)` starts the watch of the levels of cwd, so an outside write after the read is in the changes after the cursor (test aCursorWithAWorkingDirectoryWatchesItsSessionLevel).
    - Store mutations are now `async` (they wait for their log append). Each append is chained after the one before it, so the log keeps the order of the commits, and `changeCursor()` waits for the appends before it.
    - IDChange could not be used directly: ChangeLogEntry has no public init, so `IDChange(_:)` cannot take an entry of a ChangeLog<SettingsLoggedChange>. ChangedIDs, ToolkitID and DateTime are used instead.
    - Rule 10 (SUBSCRIPTION_NOT_IN_TOOL) was already covered by SettingsToolTests.theToolRefusesASubscription.
    - Full `swift test`: 1186 tests in 128 suites passed with 1 known issue (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps).
  timestamp: 2026-10-21T13:15:13.164246+00:00
- actor: claude-code
  id: 01m5f9mwgdjaxmp735p393dh1c
  text: |-
    ### implement — changed
    - evidence: 2e5fbbd feat(settings): changes(after:) with an opaque cursor, a cursor query and RESYNC_REQUIRED (^sn3pz3s); before it 563334a build(deps) (Extras ac1b9f2, Multitool c9f70cd). Full `swift test`: 1186 tests in 128 suites passed with 1 known issue. 13 files: Sources/.../Configuration/SettingsStore.swift, Configuration/SettingsLoggedChange.swift (new), Settings/SettingsEngine.swift, Settings/SettingsGraph.swift, Settings/SettingsGraphSchema.swift, Tests/Fixtures/settings.graphql, SettingsGraphTests, SettingsSubscriptionTests, SettingsToolTests, SettingsTreeDifferenceTests (new), Support/SettingsGraphFixture.swift, + this card.
    - open decision for review: one ChangeLog per store (shared by all endpoints), not one cached SettingsGraph instance per store (see the comment above).
    - next: /review
  timestamp: 2026-10-21T13:15:42.477210+00:00
- actor: claude-code
  id: 01m5fa4swd8eevmqwsybd8vhdt
  text: |-
    ### done: one settings endpoint per store (supersedes the "open decision" in the comments above)
    - The agent builds the one SettingsGraph next to its store (`RoutedACPAgent.settingsEndpoint`, made in init right after `settingsStore`). `CatalogContext.settingsEndpoint` (in place of `settingsStore`) carries that instance to every session composition, and `ToolCatalog.settingsTool(in:)` makes each session's `SettingsTool(endpoint:sessionDirectory:)` over it. `SettingsTool(store:)` is gone, so no tool builds a schema. No cycle: the agent owns both the store and the endpoint.
    - SettingsGraph is now a `final class` (Sendable), so the one instance has an identity.
    - Seam for the test: `RoutedACPAgent.catalogContext(from:workingDirectory:additionalRoots:clientMCPServers:)`, pulled out of composeSession.
    - There is no separate server-scope endpoint list in this repo: hosts get the endpoint through `SettingsTool.graphQLEndpoints`, which now gives that same instance. No sibling repo calls `SettingsTool(store:)` or `CatalogContext(settingsStore:)`.
    - RED (compile): SessionSettingsStoreTests.eachSessionSettingsToolUsesTheOneEndpointOfTheAgent → "value of type 'RoutedACPAgent' has no member 'settingsEndpoint'" / "'catalogContext'", "type 'ToolCatalog' has no member 'settingsTool'", and "argument type 'SettingsGraph' expected to be an instance of a class" (the `===` check on a struct).
    - GREEN: `swift test --filter 'SessionSettingsStoreTests|SettingsToolTests|ToolCatalogTests'` → 43 tests passed. Full `swift test`: 1187 tests in 128 suites passed with 1 known issue (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps).
    - Updated callers: SessionSetup (composeSession), ToolCatalog.makeRegistry, SettingsToolTests (tools over `fixture.graph`), ToolCatalogTests (context gets an endpoint; the registry-call test reads the stored value through the endpoint).
  timestamp: 2026-10-21T13:24:24.077085+00:00
position_column: doing
position_ordinal: '8380'
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
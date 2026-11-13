---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7b46pks1xfw5vbn0avpndkz
  text: |-
    Research (implement):
    - `reload(_:)` in SettingsStore.swift keeps the last good `root` and `text`, and only logs. The guard `text != state.text` stops a repeated read. When the bad text goes back to the last good text, that guard returns early, so the clear must happen before it.
    - The parse error text is NOT safe. `YAMLValue.parse` puts `String(describing: YamlError)` in `YAMLValueParsingError.malformed(message:)`. The Yams description of a scanner, parser, composer and reader error ends with a snippet: the YAML line of the problem and a `^` line. The parse runs on the RENDERED text, so the snippet can hold a value that a template made from the environment. The load error must remove each message line that is a line of the rendered text, and the caret line.
    - The render error text is NOT safe. Stencil errors can echo token contents and values (for example `Tuple '\(value)'`). The load error gives a fixed message for a render error, and a fixed message for a read error (not UTF-8).
    - The schema has a golden file: Tests/Fixtures/settings.graphql (`theSchemaMatchesTheGoldenFile` in SettingsGraphTests.swift). A new query field must go into it.
    - ARCHITECTURE.md has no settings section yet. Add one.
    - A `set`/`clear` after a bad reload edits the last good text and writes it, so the file is good again: the load error must clear then too.
  timestamp: 2026-11-13T18:55:00.729705+00:00
- actor: claude-code
  id: 01m7b4yzffz8arjtcxdxq3gymt
  text: |-
    Implementation landed (TDD). RED: 14 new tests failed for the expected reason (no change for a bad write, no load error); each one waited for its 1-minute time limit. GREEN: `swift test --filter 'SettingsStoreTests|SettingsSubscriptionTests'` gives 42 tests passed.
    - New type `SettingsLoadError` (Configuration/SettingsLoadError.swift). `LevelState.loadError`. `SettingsStore.loadErrors(cwd:)`. `reload(_:)` is now internal, so that a test reads the file again at a known time (the watcher can join two fast writes into one read). The read part is `reloaded(_:)`.
    - `set`/`clear` of a level with a load error clears it, and sends one more change with no key path after its own change.
    - `renderedTree` now filters the parser message for every path, so a `set` error that is a parse error also holds no snippet.
    - Endpoint: query `problems(cwd:)` gives `[SettingsProblem!]!` (level, cwd, path, line, message). Golden file recorded with `GRAPHQL_GOLDEN_RECORD=1`.
  timestamp: 2026-11-13T19:08:16.239451+00:00
- actor: claude-code
  id: 01m7b52gddx8arav5gqx8arzn9
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Configuration/SettingsLoadError.swift (new), Configuration/SettingsStore.swift, Settings/SettingsEngine.swift, Settings/SettingsGraph.swift, Settings/SettingsGraphSchema.swift, Tests/Fixtures/settings.graphql, Tests/FoundationModelsACPAgentTests/SettingsStoreTests.swift, SettingsSubscriptionTests.swift, Support/SettingsGraphFixture.swift, ARCHITECTURE.md. `swift test --filter 'SettingsStoreTests|SettingsSubscriptionTests'`: 42 passed. `timeout 900 swift test`: 2070 tests in 223 suites passed, 0 failures, 1 known issue (the existing `withKnownIssue` in HarnessSmokeTests). `swift build --build-tests --package-path IntegrationTests`: Build complete. No compiler warning. The only "warning:" line is the SwiftPM message "missing creator for mutated node" about the mlx-swift_Cmlx bundle, which comes from the build system and not from this change.
    - next: review
  timestamp: 2026-11-13T19:10:11.885402+00:00
- actor: claude-code
  id: 01m7b55ay3pp0vdx5vjywy9ja0
  text: |-
    ### test — green
    - evidence: swift test — 2070 tests in 223 suites passed, 1 known issue (the intended withKnownIssue in HarnessSmokeTests), 0 failures, 0 compiler warnings. swift build --build-tests --package-path IntegrationTests — build complete, 0 compiler warnings, 0 errors. Only the SwiftPM line "missing creator for mutated node" showed. It comes from the build system.
    - next: review
  timestamp: 2026-11-13T19:11:44.579244+00:00
- actor: claude-code
  id: 01m7b5bcmdqkys1zrq9ameceqk
  text: |-
    ### review — findings
    - evidence: review sha 4d52b67~1..4d52b67; 2 findings (2 confirmed, 3 refuted) — Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:832, Tests/FoundationModelsACPAgentTests/SettingsSubscriptionTests.swift:246
    - next: correct the 2 open items in "Review Findings (2026-11-13 13:12)", then review again.
  timestamp: 2026-11-13T19:15:02.925786+00:00
- actor: claude-code
  id: 01m7b5c0ay26g62tw3n3kdk21z
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files
    - test: green — swift test, 2070 tests in 223 suites passed, 1 known issue (intended)
    - commit: 4d52b67
    - review: findings — Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:832, Tests/FoundationModelsACPAgentTests/SettingsSubscriptionTests.swift:246
  timestamp: 2026-11-13T19:15:23.102178+00:00
- actor: claude-code
  id: 01m7b5g5cbpaqxgrsfrhp069hb
  text: |-
    Research (implement, review round 1):
    - `renderedTree(of:layer:)` has four callers: `change(at:level:transform:)` (set/clear), `levelState(of:)` (the first read of a level, also on the set/clear path), `defaultsTrees()`, and `reloaded(_:)`. Thus the filtered parser message applies to each of them. The decision (from the dispatcher): keep the filter on the set/clear path, because without it a refused `set` can echo a rendered secret value. Document it and pin it with a test.
    - A `set` is refused for a parse error when the file of the level does not parse at its first read: `levelState(of:)` throws `LayeredYAMLDocumentError.malformed`. Its `description` is the user-facing text: `layered YAML document: malformed YAML at <path>:<line>: <message>`.
    - The shared sequence of finding 2: write a good session file, open a change stream (the store tests first read the level with `merged(for:)`; `SettingsGraphFixture.changes(cwd:)` starts the watch itself), write a text from outside, and wait for the change of that write. Copies: `writeOutside` and `anOutsideWriteReloadsTheLevel` in SettingsStoreTests, `writeBadSessionFile` and `anOutsideFileChangeSendsAChange` in SettingsSubscriptionTests.
  timestamp: 2026-11-13T19:17:39.339495+00:00
- actor: claude-code
  id: 01m7b60hs14bkjn5v198qcj541
  text: |-
    ### implement — changed
    - Finding 1 (SettingsStore.swift:832, completeness/public-output-contract): the second fix. The filter stays on the set/clear path, because without it a refused `set` can echo a rendered secret value. The doc comments of `set(_:at:level:)`, `clear(at:level:)` and `SettingsStore`, and the Settings section of ARCHITECTURE.md, now tell the changed refusal message. New test `aSetRefusedForAParseErrorGivesNoLineOfTheFile` pins the full `description`: `layered YAML document: malformed YAML at <path>:2: 2:33: error: scanner: mapping values are not allowed in this context:`. RED: with the filter removed for a short time, the test failed (the message held the snippet line `trigger: hidden-file-text-4b7e: x` and the caret line). GREEN: after the filter came back, the test passed.
    - Finding 2 (SettingsSubscriptionTests.swift:246, reuse/reuse): new shared helper `OutsideSettingsWrite.write(_:over:in:expecting:sourceLocation:openChanges:nextChange:)` in Tests/FoundationModelsACPAgentTests/Support/OutsideSettingsWrite.swift. It writes the first text, opens the change stream, writes the outside text, and waits for the expected change. The caller gives the way to open the stream and to read one change. SettingsStoreTests `writeOutside` and SettingsSubscriptionTests `writeOutside` (the old `writeBadSessionFile`) call it. These copies of the same sequence now call it too: `anOutsideWriteReloadsTheLevel` and `aStartAfterAStopWatchesAgain` (SettingsStoreTests), and `anOutsideFileChangeSendsAChange` (SettingsSubscriptionTests). `aStopForgetsEachLevel`, `aSubscriptionLivesOnWhenADifferentConnectionCloses` and `aCursorWithAWorkingDirectoryWatchesItsSessionLevel` use a different sequence, so they did not change.
    - Discovery: the CLI `sah tool kanban task update --description` stopped responding and did not write (it is possibly a lock that the MCP server holds). The MCP `update task` wrote it.
    - evidence: ARCHITECTURE.md, Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift, Tests/FoundationModelsACPAgentTests/SettingsStoreTests.swift, Tests/FoundationModelsACPAgentTests/SettingsSubscriptionTests.swift, Tests/FoundationModelsACPAgentTests/Support/OutsideSettingsWrite.swift (new). `swift build --build-tests`: build complete, 0 compiler warnings. `swift test --filter 'SettingsStoreTests|SettingsSubscriptionTests'`: 43 tests passed. `timeout 900 swift test`: 2071 tests in 223 suites passed, 0 failures, 1 known issue (the existing `withKnownIssue` in HarnessSmokeTests). `swift build --build-tests --package-path IntegrationTests`: build complete. The only "warning:" line is the SwiftPM line "missing creator for mutated node" (mlx-swift_Cmlx bundle). It comes from the build system.
    - next: review
  timestamp: 2026-11-13T19:26:36.321270+00:00
- actor: claude-code
  id: 01m7b63er4ddvzdy6c3kw6m1x9
  text: |-
    ### test — green
    - evidence: swift test — 2071 tests in 223 suites passed, 1 known issue (HarnessSmokeTests, intended), 0 failures, 0 compiler warnings. swift build --build-tests --package-path IntegrationTests — Build complete, 0 compiler warnings.
    - note: the SwiftPM line "missing creator for mutated node" comes from the build system. It is not a compiler warning.
    - next: review
  timestamp: 2026-11-13T19:28:11.524644+00:00
position_column: doing
position_ordinal: '80'
title: A settings file that does not parse after an outside write gives an error to the client
---
## What
`SettingsStore` watches the `config.yaml` of each level that it read (`DotfolderWatcher` in `levelState(of:)`, `reload(_:)` in Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift). An outside write that parses replaces the level and sends a change. This works and has tests (`anOutsideWriteReloadsTheLevel` in Tests/FoundationModelsACPAgentTests/SettingsStoreTests.swift, Tests/FoundationModelsACPAgentTests/SettingsSubscriptionTests.swift).

The gap: when an outside write does not read, render or parse, `reload(_:)` keeps the last good tree and writes only a log warning. No client sees the error. The `settings` endpoint (Sources/FoundationModelsACPAgent/Settings/SettingsGraph.swift) gives no field and no event for it. TestudoApp ^8zasw13 needs the error (iCloud sync of the Agents folder, D20, D98, D163).

Do this:
- Keep a load error for each level in `LevelState` (the file path, the line when there is one, and the message). A good reload clears it.
- When the error starts, changes, or clears, send and log a `SettingsChange` with no key path for that level, so a subscriber reads again.
- Add the load error of each level to the `settings` schema (for example, a `problems` list on the query), and give it in a `settings` load.
- The values stay the last good values while the file is bad.
- The error text must not hold a secret value: give the parser message and the line, not the file text.

## Acceptance Criteria
- [ ] An outside write of YAML that does not parse keeps the last good values in `merged(for:)` and in a `settings` load.
- [ ] That write sends one change event for its level, and a `settings` load then gives the error with the file path and the line.
- [ ] A later good write clears the error, gives the new values, and sends one change event.
- [ ] A write of the same bad text again sends no second event.
- [ ] ARCHITECTURE.md and the doc comment of `SettingsStore` tell the new behavior.

## Tests
- [ ] Tests/FoundationModelsACPAgentTests/SettingsStoreTests.swift: a bad outside write keeps the values, records the error, and sends one change; a good write clears it.
- [ ] Tests/FoundationModelsACPAgentTests/SettingsSubscriptionTests.swift: the subscription gives the event, and the query gives the error and then no error.
- [ ] `swift test` passes with 0 failures and 0 warnings; `swift build --build-tests --package-path IntegrationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1

## Review Findings (2026-11-13 13:12)

> Scope: `review sha 4d52b67~1..4d52b67` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 4 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file
> - `Tests/Fixtures/settings.graphql` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:832` `completeness/public-output-contract` — `renderedTree` is shared by the outside-read path and the `change` path used by `set` and `clear`. The parse-error message is now filtered for every caller, not only for an outside read. A `set` refused for a parse error now returns a message with the line removed, which changes an existing user-facing error. The task was about load errors after an outside write, so this output change was not asked for and is not documented for the `set` path. Keep the unfiltered parser message on the `set` and `clear` path, and apply `parserMessage(_:hidingLinesOf:)` only where `reloaded` builds a `SettingsLoadError`, for example by wrapping the error there. Or document the change to the `set` refusal message and add a test that pins the new wording.
- [x] `Tests/FoundationModelsACPAgentTests/SettingsSubscriptionTests.swift:246` `reuse/reuse` — The new helper writeBadSessionFile repeats the setup of writeOutside in SettingsStoreTests. Both write sessionTriggerYAML, start a watch on the first directory, write a bad text from outside, and wait for the single nil-keyPath change. Two copies of the same watch-and-wait sequence will drift apart when one is fixed. Move the shared sequence into SettingsGraphFixture or a shared test support helper that takes a way to open the change stream (the store's changes() or the graph's changes(cwd:)). Have both test files call it, and keep only the API-specific parts in each file.

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
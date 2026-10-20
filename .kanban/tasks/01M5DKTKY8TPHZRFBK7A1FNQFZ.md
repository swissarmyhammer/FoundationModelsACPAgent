---
comments:
- actor: claude-code
  id: 01m5dm754tby95jewyf6xcbngr
  text: |-
    Research:
    - `SettingsStore.startWatching(cwd: nil)` already watches the user level only. `SettingsStore.value(at:cwd:)` needs a URL: it always merges the user level and the session level of cwd. Plan: make its `cwd` a `URL?`; `nil` merges the defaults layer and the user level over the builtin layer (no session level). The loader of the placeholder folder gives the builtin layer, which does not use the working directory.
    - The schema already names the builtin layer: `SettingLayer.BUILTIN` (and `DEFAULTS`).
    - `SettingsGraphContext.workingDirectory(given:)` throws `MISSING_CWD` for each field with no cwd on the endpoint. Plan: it gives `String?`; the engine refuses only a SESSION change with no cwd (`SettingsGraphLevel.storeLevel(cwd:)` throws `MISSING_CWD`). The session tool keeps its folder and `NOT_SESSION_CWD`.
    - The `changes` subscription with no cwd already watches the user level, but it relays each change of the store, also session changes. Plan: with no cwd, it relays user-level changes only.
    - The test `aCallWithNoWorkingDirectoryIsRefused` (query with no cwd -> MISSING_CWD) records the old contract; it changes to a SESSION set and clear with no cwd.
  timestamp: 2026-10-20T21:41:58.042271+00:00
- actor: claude-code
  id: 01m5dmj9ckewb1ry7grfwqy0a2
  text: |-
    Implementation landed (TDD: RED seen for each new test, then GREEN).
    - `SettingsStore.value(at:cwd:)` takes `URL?`. `nil` merges the defaults layer and the user level over the builtin layer, with the loader of the placeholder folder. The merge uses `SettingsLevel.watched(cwd:)`, the same level list as `startWatching(cwd:)`. `startWatching(cwd: nil)` already existed; no other store API was necessary.
    - `SettingsGraphLevel.storeLevel(cwd: URL?)` throws `MISSING_CWD` for SESSION with no cwd. The engine takes `cwd: String?` for reads and changes (`checkedLevel` helper). `SettingsGraphContext.workingDirectory(given:)` gives `String?`; the session tool path (session folder, `NOT_SESSION_CWD`) is not changed.
    - The `changes` relay with no cwd gives only user-level changes (a `where` clause). The re-read after `stopWatching()` stays.
    - Schema descriptions (cwd, Setting, setting, changes) and the golden `Tests/Fixtures/settings.graphql` updated. `MISSING_CWD` doc and message now name the SESSION change.
    - The old test `aCallWithNoWorkingDirectoryIsRefused` (query with no cwd -> MISSING_CWD) recorded the old contract; it became `aSessionChangeWithNoWorkingDirectoryIsRefused` (SESSION set and clear with no cwd).
    - Test fixture: the `settingQuery`/`setMutation`/`clearMutation` documents take a nullable `$cwd`, and the fixture call helpers take `URL?`.

    ### implement — changed
    - evidence: `swift test` 1162 tests in 125 suites, 0 failures, 0 warnings (1 known issue: the deliberate `withKnownIssue` in HarnessSmokeTests). Files: Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift, Settings/SettingsEngine.swift, Settings/SettingsGraph.swift, Settings/SettingsGraphError.swift, Settings/SettingsGraphSchema.swift, Settings/SettingsTool.swift, Tests/Fixtures/settings.graphql, Tests/.../SettingsGraphTests.swift, SettingsStoreTests.swift, SettingsSubscriptionTests.swift, Support/SettingsGraphFixture.swift.
    - next: /review
  timestamp: 2026-10-20T21:48:02.835414+00:00
- actor: claude-code
  id: 01m5dmqcqhwx653hb1kzg72vz1
  text: |-
    ### test — green
    - evidence: touched the 10 changed Swift files, then `swift test`: 1162 tests in 125 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue, accepted), 0 failed, 0 skipped. Build had no compiler warning. `swift build --build-tests --package-path IntegrationTests`: Build complete, 0 compiler warnings. Only warning in both: SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx.bundle (accepted). Settings suites (Graph, Store, Subscription, Tool, ToolSession) run 3 times: 65 tests in 7 suites passed each time.
    - next: review
  timestamp: 2026-10-20T21:50:50.097339+00:00
depends_on:
- 01M5CZ4EDEW6ECQ13W9E7QFTFW
position_column: doing
position_ordinal: '80'
title: The settings endpoint reads and writes the user level with no cwd
---
## What
D98(a) and D100(d): the Settings scene of the app writes only the user level, through the `settings` endpoint. It has no working folder. Now (cards ^cj9s5j0 and ^e7qftfw) the endpoint refuses a call with no `cwd` with the code `MISSING_CWD`, also for `set` and `clear` on the `user` level, and the `setting` query always gives the merged value of a cwd.

Do this:
- `set` and `clear` with `level: user` need no `cwd`. With `level: session`, `cwd` stays required on the endpoint (`MISSING_CWD`), and the session tool keeps its own folder.
- A query with no `cwd` gives the value of the user level merged over the built-in layer (no session level), and the level that set it (`user` or the built-in level). Give the built-in level a name in the schema if it has none.
- The `changes` subscription with no `cwd` gives the changes of the user level.
- Update the golden schema `Tests/Fixtures/settings.graphql` and the doc comments.

## Acceptance Criteria
- [x] A user-level `set` and `clear` with no `cwd` work on the endpoint and write `<root>/config.yaml` (or the XDG user file for the CLI).
- [x] A query and a subscription with no `cwd` give the user-level values.
- [x] A session-level call with no `cwd` on the endpoint still gives `MISSING_CWD`.

## Tests
- [x] A test for each criterion with temporary folders.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-17
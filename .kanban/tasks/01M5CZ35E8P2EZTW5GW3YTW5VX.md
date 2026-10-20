---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dafndnpj84zg3r2nwdh6y0
  text: |-
    Research done. Findings:
    - `LayeredYAMLDocument` has only `load(_:from:engine:context:)`; its init and merge are private. Thus the store reads each level with a one-layer `DotfolderStack` (render and parse as the loader does), and merges the levels in memory with its own merge that records the source of each key the same way.
    - `ConfigurationLoader.load()` will split: the stack read, then one shared step over a dotfolder root and its sources (builtin under it, schemaWarnings, decode, secret resolve, defaults, code override). `SettingsStore.merged(for:)` calls that shared step. A second shared step checks a root (schemaWarnings and decode, no log, no Keychain) for `set` and `clear`.
    - `ConfigurationYAML` emits from a JSON tree. The flush adds a `YAMLValue` entry point over the same private line emitter. A double-quoted scalar must escape a newline, or the round trip of a flush changes the value.
    - The level files hold the rendered tree: the flush writes the rendered values, thus comments and template tags of the file may go. A `keychain:` reference is text in the tree, thus the flush keeps it.
    - `DotfolderWatcher(roots:)` accepts a file URL as a root (a missing file arms its nearest ancestor). The store uses one watcher for each `config.yaml` that it read.
    - `loadSessionContext` becomes async (the store is an actor). Callers: `composeSession`, `restoreSession`, `candidateTranscriptRoots`.
  timestamp: 2026-10-20T18:51:51.093539+00:00
- actor: claude-code
  id: 01m5db4zq7br96whs0trmt2sta
  text: |-
    Implementation landed (TDD: SettingsStoreTests and SessionSettingsStoreTests failed first, then passed).
    - `Configuration/SettingsStore.swift`: actor `SettingsStore`, with `SettingsLevel` (`.user`, `.session(URL)`), `SettingsChange` (level and key path, no value), `SettingsValue` (value and `ConfigurationLayerName`), `SettingsStoreError.noLayer`. API: `merged(for:)`, `value(at:cwd:)`, `set(_:at:level:)`, `clear(at:level:)`, `changes()`.
    - `merged(for:)` gives `LoadedConfiguration` (configuration, warnings, sources). It is the existing type for "(AgentConfiguration, sources)", and the session paths need its warnings too.
    - `Configuration/SettingsTree.swift`: key path set and remove on `YAMLValue`, and `MergedSettings`, a merge with the source of each key path by the rule of `LayeredYAMLDocument` (its merge is private in Extras).
    - `ConfigurationLoader`: `load()` now calls the shared `loadedConfiguration(dotfolderRoot:sources:)`; new `check(dotfolderRoot:)` (schema check and decode, no log, no Keychain) for set and clear.
    - `ConfigurationYAML.levelText(of:)`: emits a level tree with the private line emitter. `quoted` now escapes a line break, a carriage return and a tab, because YAML folds a line break in a double-quoted scalar.
    - `RoutedACPAgent.settingsStore`; `makeConfigurationLoader` comes from the store; `loadSessionContext` is async and reads `settingsStore.merged(for:)`. Callers: `composeSession`, `restoreSession`, `candidateTranscriptRoots` (now async; its two `try?` became do/catch with a warning record).
    Known limits (documented in code): the flush writes the rendered tree, thus comments and template tags of a level file go. A `{% include %}` of a level file finds a partial only in its own level folder. The defaults layer (`<NAME>_DEFAULTS_DIR`) is not a level; each merge reads it from disk. An empty `config.yaml` sets no key in the store (the loader merges it as null).
  timestamp: 2026-10-20T19:03:29.767326+00:00
- actor: claude-code
  id: 01m5db5362ez3zcedatfzfy0wm
  text: |-
    ### implement — changed
    - evidence: `swift test` 1064 tests in 118 suites passed, 0 failures, 0 warnings (1 known issue is the existing `withKnownIssue` in HarnessSmokeTests). New: SettingsStoreTests (10), SessionSettingsStoreTests (1). Files: Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift, Configuration/SettingsTree.swift, Configuration/ConfigurationLoader.swift, Configuration/ConfigurationYAML.swift, RoutedACPAgent.swift, Agent/SessionSetup.swift, Agent/SessionResume.swift, Agent/SessionLifecycle.swift, Tests/FoundationModelsACPAgentTestSupport/SettingsFoldersFixture.swift, Tests/FoundationModelsACPAgentTests/SettingsStoreTests.swift, Tests/FoundationModelsACPAgentTests/SessionSettingsStoreTests.swift
    - next: /review
  timestamp: 2026-10-20T19:03:33.314174+00:00
- actor: claude-code
  id: 01m5dbhcckheq9k80fhcen61p3
  text: |-
    Coordinator fix (D101): the flush no longer writes rendered template values.
    - The store keeps the source text of each level (before the render) and its rendered tree. It renders only to merge, check and decode (`renderedTree(of:layer:)`, same trust rule and error types as `LayeredYAMLDocument`).
    - New `Configuration/SettingsSourceText.swift`: the source tree of a level text. Each `{{ ... }}` expression becomes a token; the write emits the tree and puts the original expression text back. `set` and `clear` change this source tree; the flush writes it.
    - New `SettingsTemplateError.unkeptTemplate(keyPath:)`: a change is refused, and the file does not change, when the level file holds a block tag `{% %}` or a comment tag `{# #}`, when a templated key is on the way to the key, when the path goes below a templated value, or when an embedded expression holds a quote or a backslash that the double-quoted emitter cannot keep.
    - Note: a file with a block tag refuses each change of its level (also a key outside the block), because a write regenerates the whole file and cannot keep the block.
    - Tests: `aFlushKeepsEachTemplateExpression` (`{{ HOME }}` on another key stays, the HOME value is not in the file) and `aChangeUnderABlockTagIsRefused` (error names `compaction.trigger`, file unchanged). Both failed first.
  timestamp: 2026-10-20T19:10:15.955378+00:00
- actor: claude-code
  id: 01m5dbhfb2ebehyr2j10n6qgx5
  text: |-
    ### implement — changed
    - evidence: `swift test` 1066 tests in 118 suites passed, 0 failures, 0 warnings (1 known issue is the existing `withKnownIssue` in HarnessSmokeTests). SettingsStoreTests now 12, SessionSettingsStoreTests 1. Files: Configuration/SettingsStore.swift, Configuration/SettingsSourceText.swift (new), Configuration/SettingsTree.swift, Configuration/ConfigurationLoader.swift, Configuration/ConfigurationYAML.swift, RoutedACPAgent.swift, Agent/SessionSetup.swift, Agent/SessionResume.swift, Agent/SessionLifecycle.swift, TestSupport/SettingsFoldersFixture.swift, Tests/SettingsStoreTests.swift, Tests/SessionSettingsStoreTests.swift
    - next: /review
  timestamp: 2026-10-20T19:10:18.978466+00:00
- actor: claude-code
  id: 01m5dbnnc3jqzy064ph2b473f6
  text: |-
    ### test — green
    - evidence: `swift test`: 1066 tests in 118 suites passed, 1 known issue (the accepted withKnownIssue test). `swift build --build-tests --package-path IntegrationTests`: build complete. After touching the 12 changed files, `swift build --build-tests`: build complete, no compiler warning. The only warning is the accepted SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx. `SettingsStoreTests` and `SessionSettingsStoreTests` run three times: 13 tests in 2 suites passed each time.
    - next: review
  timestamp: 2026-10-20T19:12:36.227525+00:00
- actor: claude-code
  id: 01m5dbxzka992ch08m5rfhb3vt
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit ee08458); 6 findings (6 confirmed, 1 refuted) — SettingsStore.swift:185, SettingsStore.swift:263, SettingsStore.swift:475, SessionSettingsStoreTests.swift:22, SessionSettingsStoreTests.swift:36, SettingsStoreTests.swift:153
    - next: correct each open item in the 2026-10-20 14:13 Review Findings section, then run the review again.
  timestamp: 2026-10-20T19:17:08.842961+00:00
- actor: wballard
  id: 01m5dbygcandd85eb3k9q616hz
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 12 files (two implement rounds: the second keeps template tags in the flush)
    - test: green — swift test 1066 passed; store suites x3 green; IntegrationTests builds
    - commit: ee08458
    - review: findings — SettingsStore.swift:185, :263, :475, SessionSettingsStoreTests.swift:22, :36, SettingsStoreTests.swift:153
  timestamp: 2026-10-20T19:17:26.026067+00:00
- actor: claude-code
  id: 01m5dc2x1vt9q9g5d6pe6y4xk0
  text: |-
    Picked up the 2026-10-20 14:13 findings. Research:
    - `DotfolderWatcher` has `start()`, `stop()` and a `deinit` that calls `stop()`. The store holds one watcher for each level in `LevelState.watcher`, and no code reads it after the init.
    - `ACPAgentTelemetry.errorMetadata(_:sessionId:)` needs a session id. `reload` and `SessionLifecycle.logCandidateRootFailure` have no session. Plan: add `errorMetadata(_:)` (error type only), let `errorMetadata(_:sessionId:)` use it, and call it from both places.
    - `SessionSetupTests` has the same private `makeInitializedAgent` and `makeNewSessionRequest(cwd:)` as `SessionSettingsStoreTests`. Plan: `AgentClientHarness.makeNewSessionRequest(cwd:)` and `AgentClientHarness.makeInitializedAgent(label:userDirectory:)` in test support; delete both private copies.
    - `ConfigCommandFixture.configURL(in:)` (same test target) joins the same path as `SettingsStoreTests.Fixture.configFile(in:)`. Plan: call it, and delete the copy.
  timestamp: 2026-10-20T19:19:50.075094+00:00
- actor: claude-code
  id: 01m5dcjj5e4q5a97fnb92kcqby
  text: |-
    Findings of 2026-10-20 14:13 corrected:
    - `watcher`: new `SettingsStore.stopWatching()` calls `stop()` on each watcher, forgets each level and ends each `changes()` stream. A later call reads the files again and watches again (a rebind of the agent then reads fresh settings). `closeOpenSessions(after:)` calls it after the hook drain. Tests: `aStopEndsEachChangeStream`, `aStopForgetsEachLevel` (a second store is the witness of the watch period), `aConnectionCloseStopsTheSettingsWatch`.
    - Merge copy: private `mergedSettings(for:)` gives the merged tree and the loader of `cwd`; `merged(for:)` and `value(at:cwd:)` call it.
    - Log copy: new `ACPAgentTelemetry.errorMetadata(_:)` (error type only); `errorMetadata(_:sessionId:)` uses it; `SettingsStore.reload` and `SessionLifecycle.logCandidateRootFailure` call it. Test `errorMetadataWithNoSessionHoldsTheErrorTypeOnly`.
    - Test helpers: `AgentClientHarness.makeInitializedAgent(label:userDirectory:)` and `AgentClientHarness.makeNewSessionRequest(cwd:)` in test support; the private copies in `SessionSettingsStoreTests` and `SessionSetupTests` are gone and their callers changed.
    - `Fixture.configFile(in:)` is gone; `SettingsStoreTests` calls `ConfigCommandFixture.configURL(in:)` (same test target).
    Note: the `replace_all` option of the files tool did not replace more than one match in this session; one edit for each match worked.
  timestamp: 2026-10-20T19:28:23.214184+00:00
- actor: claude-code
  id: 01m5dcjnyshksrmmbnfhs5gmb7
  text: |-
    ### implement — changed
    - evidence: `swift test`: 1070 tests in 118 suites passed, 1 known issue (the existing withKnownIssue). `swift build --build-tests`: no compiler warning (only the accepted SwiftPM "missing creator" note). `SettingsStoreTests|SessionSettingsStoreTests` three times: 16 tests in 2 suites passed each time. `swift build --build-tests --package-path IntegrationTests`: build complete. Files: Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift, Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift, Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift, Tests/FoundationModelsACPAgentTestSupport/Harness.swift, Tests/FoundationModelsACPAgentTests/ACPAgentTelemetryTests.swift, Tests/FoundationModelsACPAgentTests/SessionSettingsStoreTests.swift, Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift, Tests/FoundationModelsACPAgentTests/SettingsStoreTests.swift. All 6 findings checked.
    - next: /review
  timestamp: 2026-10-20T19:28:27.097541+00:00
- actor: claude-code
  id: 01m5dcq5mgaf365wc78e8kez2k
  text: |-
    ### test — green
    - evidence: touched the 8 changed files, then `swift test` — 1070 tests in 118 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue), 0 failures, 0 compiler warnings. `swift build --build-tests --package-path IntegrationTests` — Build complete, 0 compiler warnings. `swift test --filter 'SettingsStoreTests|SessionSettingsStoreTests'` run 3 times — 16 tests in 2 suites passed each time. Only warning: the accepted SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx.bundle.
    - next: review
  timestamp: 2026-10-20T19:30:54.224222+00:00
depends_on:
- 01M5CZ1Y88XJXTTF4XCZT60YV4
position_column: doing
position_ordinal: '8280'
title: 'ACPA-17: a settings object in memory for each level, flushed to config.yaml and reloaded on outside change'
---
## What
ACPA-17 and D100(f): ACPAgent keeps one settings object in memory for each level that it has read (the user level, and the session level of each cwd). A change goes to the object of its level, then ACPAgent flushes that object to the `config.yaml` of that level. The sessions read the merged settings from the objects in memory. When the file changes from outside (for example iCloud brings a change from another device), ACPAgent reads it again into the object.

Now the configuration is loaded fresh for each session request (`RoutedACPAgent.makeConfigurationLoader`, `SessionSetup.swift:793`; `loadSessionContext`, line 810). The merge is at the YAML level (`LayeredYAMLDocument` and `builtinRoot.layered(under:)`), and `sources` keeps the layer of each key. There is no config watcher. `DotfolderWatcher(roots:|stack:, onChange:)` exists in Extras. `LayerFileWriter` writes layer files.

Do this:
- Add an actor `SettingsStore` (in `Configuration/`). It holds one YAML document for each level: `.user` and `.session(cwd)`. Use `SettingsFolders` of card ^zt60yv4 for the paths.
- API: `merged(for cwd:) -> (AgentConfiguration, sources)`, `value(at keyPath:, cwd:) -> (value, level)`, `set(_ value:, at keyPath:, level:)`, `clear(at keyPath:, level:)`, and `changes() -> AsyncStream<SettingsChange>`.
- A `set` or `clear` checks the result with `schemaWarnings` and refuses a change that does not decode. Then it writes the document of the level to its `config.yaml` with an atomic write. Comments of the file may go; document this.
- A `DotfolderWatcher` on each `config.yaml` that the store has read. When the file changes and the content is not the last content that the store wrote, the store reads it again and sends a change.
- `loadSessionContext` and the session start paths use `SettingsStore.merged(for:)` and not a fresh load.
- The secret rule of ACPA-18 for the flush is a separate card. This card must keep each `ConfiguredSecret` as it is in the file.

## Acceptance Criteria
- [x] A `set` on the user level changes the merged value for all cwds that do not set the key, and writes `<user>/config.yaml`.
- [x] A `set` on a session level wins over the user level for that cwd only, and writes `<cwd>/.acp-agent/config.yaml` (or the folder that `SettingsFolders` gives).
- [x] A `clear` on the session level makes the user value apply again.
- [x] An outside write to a `config.yaml` updates the merged value and sends one change.
- [x] A change that does not decode is refused, and the file does not change.

## Tests
- [x] Unit tests of `SettingsStore` with temporary folders for each criterion.
- [x] A watcher test that writes the file from outside and waits for the change (with a timeout, no sleep loop).
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-17

## Review Findings (2026-10-20 14:13)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 12 file(s) reviewed, 10 not reviewed.

> 10 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 10 file(s)

- [x] `Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:185` `code-hygiene/dead-code-swift` — var.instance `watcher` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:263` `duplication/duplication` — The same two-line body is repeated in `value(at:cwd:)` and `merged(for:)`. Both build the merged settings of the user level and the session level of `cwd` with the same expression. A change to the level order or the merge inputs must be made in both places, and they can drift apart. The `makeConfigurationLoader(workingDirectory: cwd)` call is also repeated with it. Extract a private helper, for example `mergedSettings(for cwd: URL) throws -> MergedSettings`, that holds the level list and the merge. Call it from `merged(for:)` and `value(at:cwd:)`. Keep the loader call in the helper too if it reads the same cwd.
- [x] `Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:475` `duplication/duplication` — The warning log record with the error type metadata is written again here. The same pattern is in `SessionLifecycle.logCandidateRootFailure`, which this change also added. The two blocks differ only by the logger category and the message. Each copy must keep the same metadata key and the same error type rule. Check whether `ACPAgentTelemetry.errorMetadata` (or a similar helper) already builds this metadata. If so, call it here. If not, add one shared helper that takes the category and the message and writes the warning, then call it from both `reload` and `logCandidateRootFailure`.
- [x] `Tests/FoundationModelsACPAgentTests/SessionSettingsStoreTests.swift:22` `reuse/reuse` — makeInitializedAgent(label:) repeats the setup that an existing suite helper already performs: it builds a stub agent over temporary folders and runs initialize. Each suite keeps its own copy, so the setup is duplicated. Move the shared initialized-agent builder to Tests/FoundationModelsACPAgentTestSupport and have these suites call it, passing the label and any folder overrides.
- [x] `Tests/FoundationModelsACPAgentTests/SessionSettingsStoreTests.swift:36` `reuse/reuse` — makeNewSessionRequest(cwd:) reimplements an existing helper. The new code builds the same NewSessionRequest from a URL that a shared test helper already builds, so the copy can drift from the original. Move the helper to the shared test support module, or call the SessionSetupTests version, and delete this copy.
- [x] `Tests/FoundationModelsACPAgentTests/SettingsStoreTests.swift:153` `reuse/reuse` — Fixture.configFile(in:) rebuilds the config.yaml URL of a layer root. The same path join already exists in a test support fixture, so the config file name is now joined in two places. Call the existing configURL helper, or move one shared helper to the test support module and have both fixtures use it.

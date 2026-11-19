---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tyjap2m1vvh5cdb2rpgye7
  text: |-
    Dependency available (2026-11-19): FoundationModelsACP `ACPImport` (D209) is on main at b4b7abf. Still waiting for Extras, Multitool and Router.
    - Product `ACPImport` (depends only on FoundationModelsACP). It has no file access: the importer reads the file, and the reader takes `Data`.
    - `ClaudeCodeSessionReader(sourceID: <file name with no .jsonl>)` and `CodexSessionReader(sourceID: nil)` (the Codex id comes from `session_meta`).
    - `read(_:) throws -> ImportedSession` (`metadata`, `updates: [SessionUpdate]`, `skippedRecordCount`, `skippedKinds`); `metadata(_:) throws -> ImportedSessionMetadata` (`agent`, `sourceID`, `cwd`, `title`, `firstDate`, `lastDate`, `turnCount`), a fast scan (50 MB in well under 1 s). Use `metadata(_:)` for the list.
    - Errors: `ImportReadError.noReadableRecord`, `.notThisFormat`.
    - For ^fvz5m50: the updates fold in `SessionMergeEngine` with no unknown entry; a compaction is a `compaction_update` (status completed). For the model transcript: a tool call is a `tool_call_update` (pending, with title and kind), then content chunks, then a final status update; thoughts are `agent_thought_chunk`.
  timestamp: 2026-11-19T22:24:21.186196+00:00
- actor: claude-code
  id: 01m7v0pd5ts7svnf78gm5cr13j
  text: |-
    Dependency available (2026-11-19): the Multitool `SessionImporter` protocol is on origin/main, commit d8bfae93 (head f47cd992; tested against Extras cdc6179). Still waiting for Router part 2 (^0hdvn00, `RouterSessionDirectory.importSession(_:transcript:)`) for ^fvz5m50; this task (^ck8e0sx) can start now.
    API (Sendable, Equatable, Codable, public memberwise inits):
    - `protocol SessionImporter: Sendable { func importable(_ request: ImportableSessionsRequest) async throws -> ImportableSessionsPage; func importSession(_ request: SessionImportOrder) async throws -> SessionImportResult }`
    - `ImportableSessionsRequest` (agent, folder, preferredFolder, limit, cursor); `ImportableSession` (agent, sourceID, sourcePath, title, folder, lastDate, turnCount, previousImports); `SessionPreviousImport` (session, importedAt); `ImportableSessionsPage` (sessions, nextCursor, unreadableSources); `SessionImportOrder` (agent, source, folder, name); `SessionImportResult` (session, name, skippedRecordCount).
    - NEW: `public enum SessionImportError: Error` with `.sourceUnreadable(agent: String)` (no grant for that agent's folder) and `.folderUnavailable(URL)` (the target folder does not exist or has no grant). Throw these: Multitool maps them to NO_SOURCE_ACCESS and IMPORT_FOLDER_UNAVAILABLE; any other error gives IMPORT_FAILED.
    - Host API: `SessionsTool(directory:exporter:searcher:sharer:importer:)`, `SessionsGraph.endpoint(of:exporter:searcher:sharer:importer:)` (nil default). No importer: IMPORT_UNAVAILABLE.
    - After an import, Multitool reads the new session's name and short id from the directory, so `importSession` must make the session in the directory (through `SessionDirectory.importSession`) before it returns (^fvz5m50).
    NOTE: the sharer task ^7bgkh9p (in work) also changes the SessionsTool/endpoint calls; do this task after it, or merge with care.
  timestamp: 2026-11-19T23:01:31.962061+00:00
- actor: claude-code
  id: 01m7v2a0mbfnyhm9n6hw73g89j
  text: |-
    Research (2026-11-19):
    - Multitool pin moved to e76d7a6 with `swift package update FoundationModelsMultitool` (has d8bfae93: `SessionImporter`, `SessionImportError`, `SessionsTool(directory:exporter:searcher:sharer:importer:)`). ACP pin b4b7abf has `ACPImport`; Extras cdc6179 has `importedFrom`.
    - `SessionsTool.init` gives the importer to the shared `SessionsGraph` endpoint of the directory, thus one argument covers the tool and the endpoint (the same as the sharer).
    - `InMemorySessionDirectory` (Extras) implements `importSession(_:transcript:)` with a launcher, so a unit test can make sessions with `importedFrom` with no Router.
    - Multitool shows each importer error with `"\(error)"` in the IMPORT_FAILED corrective; only `SessionImportError` maps to NO_SOURCE_ACCESS / IMPORT_FOLDER_UNAVAILABLE.
    - Plan: `Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift` (an actor: roots, directory, metadata cache by path + size + modification date). `importSession` here does only the checks (unknown agent, `sourceUnreadable`, `folderUnavailable`) and then throws a typed error; ^fvz5m50 writes the session.
  timestamp: 2026-11-19T23:29:43.051935+00:00
- actor: claude-code
  id: 01m7v2ye8a38xv3t13ehfb9drn
  text: |-
    Implementation landed (not committed). New: `Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift` (actor; `AgentSessionImportError`; `ImportSourceKey`) and `Import/ImportSourceScan.swift` (`ImportSourceLayout` as data per agent, `ImportFileStamp`, `ImportFileScan`, `LocatedSessionMetadata`). Wiring: `RoutedACPAgent.init(importRoots:)` + `sessionImporter`, `ComposedAgent.compose(importRoots:)`, `CatalogContext.sessionImporter`, `ToolCatalog.makeSessionsTool` gives `importer:`, CLI `AgentComposition.importRoots(environment:homeDirectory:)` (home folder, `CLAUDE_CONFIG_DIR`). `ACPImport` product added to the library, CLI, test support and test targets in Package.swift. Docs: ARCHITECTURE.md (new section) and README.md.
    Discoveries:
    - A test that restores a modification date read with `attributesOfItem` fails: the restored date loses its sub-second part, so the stamp changes. The test sets a whole-second date on both writes.
    - `importSession` here does the checks only (unknown agent, `sourceUnreadable`, `folderUnavailable`) and then throws `SessionDirectoryError.importUnsupported`; ^fvz5m50 replaces that last throw with the write.
    - The card names only `CLAUDE_CONFIG_DIR`; the CLI does not read `CODEX_HOME` (Codex has that variable). Not added, because the card does not name it.
  timestamp: 2026-11-19T23:40:52.362314+00:00
- actor: claude-code
  id: 01m7v32magx85f4sdxvv5f858z
  text: |-
    ### implement — changed
    - evidence: 18 files — new: Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift, Sources/FoundationModelsACPAgent/Import/ImportSourceScan.swift, Tests/FoundationModelsACPAgentTests/AgentSessionImporterTests.swift (15 tests), Tests/FoundationModelsACPAgentTests/SessionImportWiringTests.swift (2 tests); changed: Package.swift, ARCHITECTURE.md, README.md, RoutedACPAgent.swift, ComposedAgent.swift, Agent/SessionSetup.swift, Tools/CatalogContext.swift, Tools/ToolCatalog.swift, Sources/acp-agent/AgentComposition.swift, Tests/FoundationModelsACPAgentTestSupport/StubProfileFixtures.swift, Tests/.../Support/ScriptedPromptFixture.swift, Tests/.../AgentCompositionTests.swift (2 tests), Tests/.../SessionSettingsStoreTests.swift (doc link). RED: `swift build --build-tests` failed on missing symbols; GREEN: the 31 tests of the 3 suites pass.
    - next: review

    ### test — red
    - evidence: `swift build --build-tests` gave "Build complete!" with no compiler warning. `timeout 1800 swift test --skip-build`: 2688 tests in 284 suites, 2 issues (1 known issue, 1 failure). The failure is `BlockingFIFOTests.theReaderReadsTheTextAfterItOpensThePipe()` (EAGAIN, NSCocoaErrorDomain 256), in a file this diff does not touch. `--filter BlockingFIFOTests` alone then passed 3 of 3. The flake is recorded as task ^v3244ag... see the new card "BlockingFIFOTests.theReaderReadsTheTextAfterItOpensThePipe fails at times in the full suite (EAGAIN)".
    - next: the coordinator decides about the unrelated flaky test; then review
  timestamp: 2026-11-19T23:43:09.648519+00:00
- actor: claude-code
  id: 01m7v32wqdrxywt7e9s5zxrdyf
  text: 'Correction to the test record above: the card of the flaky test is ^rh5d00n.'
  timestamp: 2026-11-19T23:43:18.253816+00:00
position_column: doing
position_ordinal: '8180'
title: 'D209: AgentSessionImporter lists the importable sessions of the host roots (Claude Code, Codex)'
---
Decision D209 in `TestudoApp/features/decisions.md` (commit 56a8a59; final), parts (a)–(j), (l), (m), with the answers Q81–Q87 in D209 (n). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/import/acpa-brief.md`, change items 1, 2, 5 and 6. Overview: `overview.md` in the same folder. Wave 3.

## Dependencies (not on this board; wait for all shas)

- FoundationModelsACP on `main`: the `ACPImport` target (Claude Code and Codex readers, the metadata scan).
- FoundationModelsExtras on `main`: `SessionDirectoryOrigin.import`, `SessionImportProvenance`, `SessionSummary.importedFrom`.
- FoundationModelsMultitool on `main`: the `SessionImporter` protocol and its value types, `list imports`, `import session`, the endpoint fields.
- FoundationModelsRouter on `main` (for the import task after this one).

## Change

1. **The roots.** `ComposedAgent.compose` (and `RoutedACPAgent.init`) take `importRoots: [ImportSourceAgent: URL]`: the folders of the source agents that the host can read (`~/.claude`, `~/.codex`; the app gives the bookmarked folders in Testudo, the real home folder in OpenTestudo). Default empty. The `acp-agent` CLI gives the real home folder, and `CLAUDE_CONFIG_DIR` when it is set. A source with no root is in `unreadableSources`.
2. **The scan.** `AgentSessionImporter: SessionImporter`. `importable` lists the files of each root (`projects/*/*.jsonl` for Claude Code; `sessions/**/rollout-*.jsonl` and `archived_sessions/` for Codex), reads the metadata with the `ACPImport` readers, and orders the rows newest first, with the rows of `preferredFolder` first. It keeps the metadata of each file by path, size and modification date in memory, so a second call reads only the changed files.
3. **Earlier imports.** `previousImports` (the id and the import date of each earlier copy) comes from `importedFrom` of the sessions of the directory (agent and source id). Information only (Q85): it does not change what an import does.
4. **The wiring.** Give the importer to `SessionsTool` and to the `sessions` endpoint (the Multitool host API), beside the exporter and the searcher.
5. **No background work.** The importer reads the roots only in a call. It runs no child process (D128), watches nothing, and changes no file of a root.

## Tests

- With fixture roots in a temporary folder: `importable` lists both agents in the right order (newest first, preferred folder first); a changed file is read again, an unchanged file is not; a source with no root is in `unreadableSources`.
- `previousImports` lists the earlier copies of a source.
- The import roots stay unchanged (bytes and dates). #d209 #import
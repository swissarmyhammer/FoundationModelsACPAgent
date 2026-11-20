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
- actor: claude-code
  id: 01m7v3hs42jcjgepjbbq5njx6g
  text: |-
    ### review — findings
    - evidence: `review sha b7b2c67~1..b7b2c67`; 11 findings (11 confirmed, 2 refuted). Package.swift:69, Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift:100, :346, :354, :357, Sources/FoundationModelsACPAgent/Import/ImportSourceScan.swift:38, :70, :73, :79, Sources/acp-agent/AgentComposition.swift:160, Tests/FoundationModelsACPAgentTests/SessionImportWiringTests.swift:39.
    - next: Correct each item in the "Review Findings (2026-11-19 17:44)" section. Then do the review again. The task stays in review.
  timestamp: 2026-11-19T23:51:26.082039+00:00
- actor: claude-code
  id: 01m7v3tq1avjf62b2yy5243p9t
  text: |-
    Review findings pass (2026-11-19), work in progress:
    - The `assignOnlyProperty` findings (`ImportSourceKey.agent`, `.sourceID`, `ImportFileStamp.size`, `.modified`) are reads of the synthesized `Hashable` / `Equatable` conformance. The written rule "Dead Code — Swift" section "`assignOnlyProperty` and the reads periphery cannot see" tells: do not delete such a property; write `// periphery:ignore` above it with the reason on its own line. That is the fix.
    - `isFolder(_:)` is gone; the two call sites use `PathKind.of(_:) == .directory`. The folder check of `importSession` is now `requireFolder(_:)` with two `guard` statements.
    - `ImportFileStamp.of(_:)` is now `makeStamp(of:)`. The Claude Code depth 2 is `ImportSourceLayout.claudeCodeFileDepth`.
    - Package.swift: `makeWireProduct(name:)`; `markdownProduct` and `importProduct` both use it.
    - CLI: a `CLAUDE_CONFIG_DIR` that is not absolute gives a warning (metadata key `variable`), test `aRelativeClaudeConfigDirGivesAWarning`.
    - Tests: the shared fixture `Tests/FoundationModelsACPAgentTests/Support/ImportSessionFiles.swift` writes the Claude Code and Codex session files for both import suites.
  timestamp: 2026-11-19T23:56:18.858219+00:00
- actor: claude-code
  id: 01m7v47kez9gn2zja18m776b3s
  text: |-
    Discovery: the first full run failed `NoUnifiedLoggingTests.noSourceFileUsesUnifiedLoggingOrAKeptLogger` on my first form of the CLI logger (`private static var logger: Logger { … }`): the guard forbids each static Logger declaration by its text. Fix: the CLI makes `Logger(label: logLabel)` at the warning. The same kept-logger defect was in `AgentSessionImporter` (`private static let logger = ACPAgentTelemetry.logger(.session)`; the guard did not see it because the line has no `Logger(`). It now calls `ACPAgentTelemetry.logger(.session)` at each log, as the rest of the library does. README: `CLAUDE_CONFIG_DIR` that is not absolute gives a warning on stderr. An empty `CLAUDE_CONFIG_DIR` is the same as no variable (the same as `ACP_AGENT_HOME`).

    ### implement — changed
    - evidence: 10 files — Package.swift, README.md, Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift, Sources/FoundationModelsACPAgent/Import/ImportSourceScan.swift, Sources/acp-agent/AgentComposition.swift, Tests/FoundationModelsACPAgentTests/AgentCompositionTests.swift (new test aRelativeClaudeConfigDirGivesAWarning: RED, then GREEN), Tests/FoundationModelsACPAgentTests/AgentSessionImporterTests.swift, Tests/FoundationModelsACPAgentTests/SessionImportWiringTests.swift, new Tests/FoundationModelsACPAgentTests/Support/ImportSessionFiles.swift. The 11 findings of "Review Findings (2026-11-19 17:44)" are checked.
    - next: test

    ### test — green
    - evidence: `swift build --build-tests` gave "Build complete!" with 0 compiler warnings in project sources. `swift test --skip-build --filter "AgentSessionImporter|SessionImportWiring|AgentComposition|NoUnifiedLogging"`: 35 tests in 4 suites pass. `timeout 1800 swift test --skip-build`: 2689 tests in 284 suites pass, 0 failures (1 known issue, recorded with withKnownIssue before this change).
    - next: review
  timestamp: 2026-11-20T00:03:21.183801+00:00
- actor: claude-code
  id: 01m7v4faf2t536bxmqvqgvbg02
  text: |-
    ### review — findings
    - evidence: `review sha ba7ae6e~1..ba7ae6e`; 2 findings (2 confirmed, 1 refuted). Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift:114, Tests/FoundationModelsACPAgentTests/AgentCompositionTests.swift:247. All 11 items of the 17:44 section are checked.
    - next: Correct the 2 items in the "Review Findings (2026-11-19 18:03)" section. Then do the review again. The task stays in review.
  timestamp: 2026-11-20T00:07:34.114715+00:00
- actor: claude-code
  id: 01m7v4qs527cjq4me5fxhn40na
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift (new `stamp(of:)` and `isRegularFile(_:)` each log a warning with the path of a skipped file through the shared `logSkippedFile(_:_:error:)`, with `ACPAgentTelemetry.logger(.session)` at the call; the same cause was also in the `try?` regular-file filter of `files(under:)`, now removed), Tests/FoundationModelsACPAgentTests/AgentSessionImporterTests.swift (2 new tests: RED, then GREEN), Tests/FoundationModelsACPAgentTests/AgentCompositionTests.swift (the relative `CLAUDE_CONFIG_DIR` test also checks that the root stays `~/.claude`). The 2 findings of "Review Findings (2026-11-19 18:03)" are checked.
    - next: test

    ### test — green
    - evidence: `swift build --build-tests` gave "Build complete!" with 0 project warnings. `swift test --skip-build --filter "AgentSessionImporter|SessionImportWiring|AgentComposition|NoUnifiedLogging"`: 37 tests in 4 suites pass. The coordinator did not ask for a full suite run for this change.
    - next: review
  timestamp: 2026-11-20T00:12:11.298793+00:00
- actor: claude-code
  id: 01m7v4zkcrb88d5z2xmhf0vy1z
  text: |-
    ### review — findings
    - evidence: `review sha 3ff3708~1..3ff3708` (HEAD~1..HEAD); 1 finding (1 confirmed, 1 refuted). Tests/FoundationModelsACPAgentTests/AgentSessionImporterTests.swift:393. All 13 items of the 17:44 and 18:03 sections are checked.
    - next: Correct the item in the "Review Findings (2026-11-19 18:12)" section. Then do the review again. The task stays in review.
  timestamp: 2026-11-20T00:16:27.544479+00:00
- actor: claude-code
  id: 01m7v5398wb6z45rzkjwhdpd3d
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/AgentSessionImporterTests.swift. The two skip tests are now one parameterized test `aFileThatAReadCannotReadGivesAWarning(_:)` over `SkippingRead.allCases` (`stamp`, `kind`). The one-use helpers `logRecords(of:)` and `holdWarning(_:about:)` are folded into its body. The finding of "Review Findings (2026-11-19 18:12)" is checked.
    - next: test

    ### test — green
    - evidence: `swift build --build-tests` gave "Build complete!" with 0 project warnings. `swift test --skip-build --filter "AgentSessionImporter|NoUnifiedLogging"`: 19 tests in 2 suites pass; the parameterized test ran 2 test cases (stamp, kind).
    - next: review
  timestamp: 2026-11-20T00:18:28.252667+00:00
- actor: claude-code
  id: 01m7v57v30d7a8c5kbmnw5r8n9
  text: |-
    ### review — clean
    - evidence: `review sha 694fccb~1..694fccb` (HEAD~1..HEAD); 0 findings (0 confirmed, 0 refuted). All 14 items of the 17:44, 18:03 and 18:12 sections are checked.
    - next: none. The task is in done.
  timestamp: 2026-11-20T00:20:57.568963+00:00
position_column: done
position_ordinal: ffffffb080
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

## Review Findings (2026-11-19 17:44)

> Scope: `review sha b7b2c67~1..b7b2c67` — reviewed the diffs only — lines this change added or modified. 15 file(s) reviewed, 6 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file
> - `README.md` — no validator matches this file

- [x] `Package.swift:69` `duplication/duplication` — The new `importProduct` declaration repeats the `markdownProduct` declaration (lines 61-62) with only the product name and the constant name changed. Both are `Target.Dependency.product(name:package:)` on `wireDependencyName`. Two declarations that differ only by a value should be one helper called with an argument. A later change to the wire package wiring would have to be made in each copy. Add one helper next to `makeFamilyProduct`, for example `private func makeWireProduct(name: String) -> Target.Dependency { .product(name: name, package: wireDependencyName) }`. Define `importProduct` as `makeWireProduct(name: "ACPImport")` and use the same call for the new product. Changing `markdownProduct` to use the helper would also edit unmarked lines, so either leave it as it is or report that change as a separate task.
- [x] `Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift:100` `swift/preconditions` — The folder check in `importSession` is a Boolean precondition written as an `if … { throw }`. The sibling check on the line above (`guard roots[agent] != nil else { throw … }`) uses `guard`. Mixing the two forms in one method makes the requirements read inconsistently, and `guard` is the form this validator asks for on every precondition that is not a test. Write the folder check as a guard at the head of the scope, matching the agent check: `guard let folder = order.folder, Self.isFolder(folder) else { … }` is not quite equivalent, because a missing folder must pass. Use `if let folder = order.folder, !Self.isFolder(folder) { throw … }` only if the `if` form is kept on purpose. Otherwise, express the rule as `guard order.folder.map(Self.isFolder) ?? true else { throw SessionImportError.folderUnavailable(order.folder!) }`, or keep the current form and accept the inconsistency.
- [x] `Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift:346` `reuse/reuse` — The new private helper `isFolder(_:)` re-implements a directory check that already exists. `PathKind.of(_:)` already classifies a URL as a directory, a file, or missing, with the same `FileManager.default.fileExists(atPath:isDirectory:)` call. The copy duplicates the existence and directory logic in a second place, so a later fix to one check does not reach the other. Replace the body of `isFolder(_:)` with a check of `PathKind.of(folder)` against the directory case, or call `isFolder` through `PathKind` at the two call sites (`importable` path reads at `files(under:)` and `importSession`). Keep one canonical directory check.
- [x] `Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift:354` `code-hygiene/dead-code-swift` — var.instance `agent` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift:357` `code-hygiene/dead-code-swift` — var.instance `sourceID` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Import/ImportSourceScan.swift:38` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsACPAgent/Import/ImportSourceScan.swift:70` `code-hygiene/dead-code-swift` — var.instance `size` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Import/ImportSourceScan.swift:73` `code-hygiene/dead-code-swift` — var.instance `modified` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Import/ImportSourceScan.swift:79` `swift/fluent-usage` — The static method `ImportFileStamp.of(_:)` is a factory: it builds and returns a new `ImportFileStamp`. The rule requires factory methods to begin with `make`, so the name does not match the stated convention. Rename it to `makeStamp(of file: URL) -> ImportFileStamp?`, or to `makeStamp(for file: URL)`, and update the call site in AgentSessionImporter.swift. If the team treats `of` as a conversion name, record that exception in the rule instead.
- [x] `Sources/acp-agent/AgentComposition.swift:160` `completeness/public-output-contract` — When `CLAUDE_CONFIG_DIR` is set to a relative path or to `~/...`, the `hasPrefix("/")` guard skips the override with no warning. The root silently falls back to `~/.claude`, so the operator's configured folder is ignored and `list imports` lists a different folder with no sign that the variable was rejected. The doc comment says only that an absolute folder is used, so the rejection is intended, but the silence is not. Under the rule's error-silenced check, the skip should at least warn. Log a warning when the variable is set but is not an absolute path, naming the variable and the fallback folder, then keep the fallback. The behaviour stays the same; only the silence changes.
- [x] `Tests/FoundationModelsACPAgentTests/SessionImportWiringTests.swift:39` `reuse/reuse` — makeClaudeRoot writes a Claude Code session file with an inline JSON literal. The same record is already built by claudeFile(title:) in AgentSessionImporterTests.swift (line 56), and Roots.make (line 101) writes the same file in the same change. The two fixtures can drift apart, and a change to the session format must then be made in two places. Move the Claude Code and Codex session fixtures into a shared file under Tests/FoundationModelsACPAgentTests/Support/ (or FoundationModelsACPAgentTestSupport). Have both suites call that helper and pass the root, the session id and the cwd as parameters.

## Review Findings (2026-11-19 18:03)

> Scope: `review sha ba7ae6e~1..ba7ae6e` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift:114` `completeness/public-output-contract` — A session file whose stamp cannot be read is dropped with no log. The same kind of read failure in files(under:) logs a warning, so the two paths handle the same condition in different ways. The operator gets no sign that a session file is missing from the list. Log a warning with the file path when makeStamp returns nil, in the same way files(under:) logs, and then skip the file. Add a test that covers this path, or state in the doc comment that the stamp case is silent on purpose.
- [x] `Tests/FoundationModelsACPAgentTests/AgentCompositionTests.swift:247` `completeness/public-output-contract` — The test for a relative CLAUDE_CONFIG_DIR checks only the warning. It discards the returned roots with `_ =`, so the documented fallback (the root stays ~/.claude) is never asserted. A regression that returns a wrong root on this path would still pass. Keep the roots and add #expect(roots[.claudeCode] == Self.importHome.appendingPathComponent(".claude", isDirectory: true)) to the same test, so the fallback result is proven as well as the warning.

## Review Findings (2026-11-19 18:12)

> Scope: `review sha 3ff3708~1..3ff3708` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/AgentSessionImporterTests.swift:393` `reuse/reuse` — The test `aFileWithNoKindGivesAWarning` is a near-copy of `aFileWithNoStampGivesAWarning` (line 384). Both build the same missing path with `makeResolvedDirectory(label:).appendingPathComponent("gone.jsonl")`, both call `logRecords`, and both assert `holdWarning`. They differ only in the one call inside the closure. The second test copies the first instead of sharing one parameterized body, so a change to the path setup or the assertion has to be made twice. Make one parameterized test over the two probes, for example with `@Test(arguments:)` over a list of closures or labels, or extract a helper such as `assertMissingFileWarns(_ probe: (URL) -> Void)` that both tests call. Keep the two names if a reader needs them, but share the body.
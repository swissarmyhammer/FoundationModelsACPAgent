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
position_column: todo
position_ordinal: 9a80
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
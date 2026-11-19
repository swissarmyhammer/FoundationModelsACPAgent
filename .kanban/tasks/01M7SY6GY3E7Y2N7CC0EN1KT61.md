---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7t07qawctv7tsqfx9t6v872
  text: |-
    Research (implement step):
    - Write points: `writeHistory(of:)` (SessionHistory.swift) serves the end of a prompt, the end of a mail turn (SessionBuild `mailTurnEnded`) and the teardown of `session/close`. The fork write is `mountFork` in SessionForkLaunch.swift. It runs BEFORE the directory registers the fork, so the live summary of the fork can be missing at that time. The `started(summary)` event of the directory comes after the register; the fork is then in the session table.
    - Directory change feed: `RouterSessionDirectory.events()` gives `factsChanged(SessionSummary)` (title, tags, recap, pin, last use), `archived(id:)` and `unarchived(id:)` (id only). `SubagentMessageProjector` reads the same stream (`DirectoryMessageFeed`).
    - A fork records in the folder of its source (`<root>/<source>/<fork>/`). A delete of the source removes the fork folder too, so the delete removes the items of each nested session folder as well.
    - `summary(of:)` of a session that is not live reads every recording root of the host (each registered project). The reconcile must not read a folder that cannot be read, so the reconcile reads the `index.md` records of each readable root with `RouterSessionDirectory.recordedSessions(in:)` (nested walk for the forks) and makes the session facts from the record.
    - Design: one serial job queue (`TranscriptSearchUpdates`, an AsyncStream with one consumer task). A write puts a job in the queue with no wait, so the turn does not wait. The serial order keeps a later turn after an earlier one, and a reconcile job reads its files when it runs, so it never overwrites a newer turn.
  timestamp: 2026-11-19T13:34:16.412828+00:00
- actor: claude-code
  id: 01m7t15r3g6ce0vkhtk00vt14q
  text: |-
    ### implement — changed
    - evidence: 17 files. New: Sources/FoundationModelsACPAgent/Search/TranscriptSearchUpdates.swift (the queue of changes, one consumer task at `.utility`, the reader of the directory events, the reconcile start at `.background`; `TranscriptSearchApplier` applies the changes), Search/TranscriptSearchApplier+Reconcile.swift (`RecordedSessionFolder.all(under:)` walks the `index.md` records at each depth, so it finds the forks; the reconcile of one folder). Changed: Search/TranscriptSearchIndex.swift (`SessionContent`, `index(_:removing:)` in one catalog change, `update(session:metadata:)` for the session item only, `items(of:)`, `indexedSessions()`), Search/TranscriptSessionMetadata.swift (`init(record:)`), Search/RoutedACPAgent+TranscriptSearch.swift (public `everyFolderIsReadable`, `directorySummaryReader`, `searchableHistory(of:)`, `transcriptSearchSessions(deleting:folderName:under:)`, `startTranscriptSearchUpdates(reading:)`), RoutedACPAgent.swift and ComposedAgent.swift (`readableFolder` parameter, default every folder), Agent/SessionHistory.swift (`writeHistory` gives the history after a write), Agent/SessionForkLaunch.swift (`mountFork` gives the copy), Agent/SessionLifecycle.swift (delete removes the session and each session in its folder), Telemetry/ACPAgentTelemetry.swift (`transcriptSearch` category), ARCHITECTURE.md (new section "Transcript search"). Tests: TranscriptSearchUpdatesTests (8), TranscriptSearchAgentUpdatesTests (5), TranscriptSearchIndexTests (+1).
    - RED seen for 11 of 14 new tests (empty updater bodies; the index test by a mutation). Two tests passed before the implementation and cannot fail with an updater that does nothing: aFailedIndexUpdateDoesNotStopTheTurn and theReconcileKeepsTheItemsOfAClosedFolder (theReconcileReadsNoRootOfAClosedFolder covers the same path and failed).
    - Discoveries: `MetadataSearcher.update(items:)` waits for the embed of the new items, so the queue waits for each embed. The queue runs at `.utility`, and a full parallel test run can delay it for about 30 s. Thus the new tests wait up to 90 s (time limit 3 minutes); aDeleteRemovesTheItemsOfTheSession took 29 s in the full run and 0.4 s alone. The reconcile does not call `summary(of:)` of the directory: for a session that is not live it reads the recording root of each registered project, also of a folder that cannot be read. The slug of a record follows `SessionSummary.slug` of Extras (the short id rule is copied, because Router keeps its record-to-summary function internal).
    - next: /review

    ### test — green
    - evidence: `swift build --build-tests` Build complete!, 0 compiler warnings; `timeout 1800 swift test --skip-build`: 2516 tests in 263 suites passed, 1 known issue (intended), 0 warnings. An earlier full run had 1 failure (aDeleteRemovesTheItemsOfTheSession, its 10 s wait was too short under load); the wait budget is now 90 s, and the last full run passed.
    - next: /review
  timestamp: 2026-11-19T13:50:40.240703+00:00
depends_on:
- 01M7SY663TJBRCSAEXBJEX3G34
position_column: doing
position_ordinal: '8180'
title: 'D207: keep the transcript search index current (each turn, fork, directory change and delete) and reconcile it at launch'
---
Decision D207. Brief: `/Users/wballard/github/swissarmyhammer/.briefs/search/acpa-brief.md`, change steps 4 and 6.

## Dependency

^jex3g34 (the items and the TranscriptSearchIndex).

## Current code

- The write points: `writeHistory(of:)` at the end of each prompt, of a message turn and of `session/close` (`Agent/SessionHistory.swift`); the write of a fork (`Agent/SessionFork.swift`, `Agent/SessionForkLaunch.swift`).
- The delete removes the transcript folder (`Agent/SessionLifecycle.swift`).
- The known folders: `FoundationModelsRouter` `ProjectStore.projects()`.

## Change

1. **Each turn:** after each `SessionHistoryFile.write`, apply the history to a `SessionMergeEngine`, chunk its entries, and give the chunk items of that session to the index. Off the turn: a failure is logged with `ACPAgentTelemetry`, and the turn does not stop. The registry embeds new items in its reload loop; do not embed here.
2. **Fork:** a fork's copied history is indexed as its own session.
3. **Directory changes:** on each change of the directory (rename, tags, recap, archive, unarchive), give the new session item only.
4. **Delete:** on `session/delete`, remove each item of the session.
5. Use the registry's update of some items when it is on `main`; until then, `update(items:)` with the full list.
6. **Reconcile at launch:** in the background with a low priority, for each folder of `ProjectStore.projects()` that the process can read with no prompt, read each `session-history.json`, make its chunk items, and give them to the index (the registry does no work for an item that did not change). Remove the items of each session that has no history file. Do not read a folder that the process cannot read; keep its items. The host gives the rule "this folder is readable now" as a closure; the package keeps no app path. No rebuild command and no setting (D187).

## Tests

- A turn gives the items of its session; a fork is indexed; a delete removes the items; a rename and an archive change only the session item.
- The reconcile: a changed file, a removed file, a folder that cannot be read (its items stay).
- A failure of the index does not stop the turn. #d207 #search
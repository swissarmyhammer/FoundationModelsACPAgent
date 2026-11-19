---
assignees:
- claude-code
depends_on:
- 01M7SY663TJBRCSAEXBJEX3G34
position_column: todo
position_ordinal: '8e80'
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
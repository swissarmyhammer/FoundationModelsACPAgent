---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4102b1yzs8y03jr5t0y2419
  text: Carded on the FoundationModelsRouter board as ^k1gepqc (2026-10-03), written with `sah tool kanban` because no Router session was running. It asks for `compactionStarted(id, reason)` before an automatic compaction and `compactionFailed(id, .failed(error) | .cancelled)`, with the same id as `CompactionResult.id`. Blocked until Router pushes it.
  timestamp: 2026-10-03T13:43:13.726024+00:00
position_column: todo
position_ordinal: '80'
title: 'Report upstream: Router gives no start, failure or cancel event for an automatic compaction'
---
## Why

Card ^e8hafh0 reports each Router compaction as one ACP `compaction_update` entry. For a manual `/compact` the agent calls `compact()` itself, so it sends `in_progress`, then `completed` / `failed` / `cancelled`. For an automatic compaction (the proactive fold, the overflow retry, the compaction yield) Router gives only `SessionEvent.compaction(CompactionResult)`, after the compaction is done. Thus:

- the automatic entry has no `in_progress` update; its first update is the terminal one;
- a failure or a cancel of an automatic compaction throws out of the answer with no event and no compaction id, so the client sees no entry for it, only the stop reason of the prompt.

## What to do

- Ask the FoundationModelsRouter session for a `compactionStarted(id:)` event before an automatic compaction runs, and a terminal event (or an error that names the compaction id) when it fails or is cancelled. Do not change Router from this repository.
- When Router ships it: map the start to `in_progress` and the failure / cancel to `failed` / `cancelled` in `CompactionReporter`, and add a test in `CompactionReportTests`.
- Update plan.md §8.5 (the "Automatic" bullet). #upstream
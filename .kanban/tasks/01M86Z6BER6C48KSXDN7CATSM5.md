---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: 'Content catalog (b): stamps() of the turns of each session (D214)'
---
## Problem

Brief: .briefs/FoundationModelsACPAgent-spotlight-content-catalog-2026-11-24.md, part 2. The host reads `allTurns()` to find the sessions whose turns changed. That read gives the text of every chunk of every session.

## Fix

- New public type `ContentStamp`: an opaque, stable stamp of one domain of the catalog (FNV-1a 64 of stable facts). It is the same in the next launch.
- `TranscriptSearchChanges.stamps() -> [SessionId: ContentStamp]` (`TranscriptSearchIndex.turnStamps()`). The stamp hashes the turn, the place, the kind, the date and the byte size of each chunk. It does not read the text, and it does not include the facts of the session (name, tags, recap).
- `turns(of:)` and `changes()` stay. `allTurns()` stays until the host stops its use.

## Tests

`TranscriptSearchChangesTests`: the same chunks and a rename give the same stamp, other chunks give another stamp, a removed session has none, a longer text gives another stamp, and a new index on the same folder gives the same stamps.
## Result

Done as planned. The full suite passed (2857 tests, 1 known issue).

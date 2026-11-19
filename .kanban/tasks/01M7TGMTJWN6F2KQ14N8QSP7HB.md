---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tjpw9tz89f82kxc8hx1bwb
  text: |-
    Research (aed2a00 + 5b71964):
    - The real collisions are chunk item vs session item only: the session item of `a/1` and chunk 1 of `a` both have the id `a/1`; the session item of `a/1/0` and chunk 0 of `a/1` both have `a/1/0`. Two chunk items cannot collide: the ordinal is an `Int` and holds no "/", so the text after the last "/" is the ordinal and the text before it is the session id. Two session items cannot collide, because their session ids are different.
    - `TranscriptSearchItem.id` is not coded. The decode makes the id again from the session and the content. The registry (`CatalogStore.readSnapshotBody`) checks `item.id == entry.id`, so an old store would drop as `.damaged` by accident. The registry also drops a store whose key (`CatalogPersistence.embeddingModelID`) is not the key of the snapshot, with the reason `.embeddingModel`.
    - Rule chosen: the session item id is `<session id>/` (the session id and a "/" at the end); the chunk item id stays `<session id>/<ordinal>`. A chunk item id ends with a digit, and a session item id ends with "/", so they never match. Thus each id is unique for each session id string, with no escape. The chunk ids do not change.
    - Store: the key of the stored catalog gets a version of the item id form (`<model id>+item-ids-2`). An old store has the old key, so the registry drops it at the load (`.storedCatalogDropped(reason: .embeddingModel)`), and the index starts empty. The reconcile at launch and the next change of each session build it again (the product is not shipped, so a rebuild at the start is correct).
  timestamp: 2026-11-19T18:57:07.386693+00:00
- actor: claude-code
  id: 01m7tkbcd66cpbznqp9gcv7cw9
  text: |-
    ### implement — changed
    - evidence: commit b8b204f. Files: Sources/FoundationModelsACPAgent/Search/TranscriptSearchItem.swift (session item id `<session id>/`), Sources/FoundationModelsACPAgent/Search/TranscriptSearchIndex.swift (store key `<model id>+item-ids-2`), Tests/FoundationModelsACPAgentTests/TranscriptSearchItemTests.swift (theIdOfASessionItemIsTheSessionIdAndASlash, theItemsOfSessionIdsWithASlashHaveDifferentIds), Tests/FoundationModelsACPAgentTests/TranscriptSearchIndexTests.swift (sessionIdsWithASlashKeepEachItem; the session item id in the old tests comes from the item), Tests/FoundationModelsACPAgentTests/TranscriptSearchPersistenceTests.swift (anOldFormCatalogIsDropped, theNextIndexBuildsAnOldFormCatalogAgain, OldFormTranscriptSearchItem writes an old-form store; aDeleteRemovesOnlyTheIdsOfThatSession takes the new session item id). RED before the fix: 4 of the 5 new tests failed (the rebuild test passes on both, because the rebuild itself does not change).
    - Rule: `<session id>/` for a session item, `<session id>/<ordinal>` for a chunk item. Store: drop and rebuild on the key change.

    ### test — green
    - evidence: `swift build --build-tests` = "Build complete!", 0 compiler warnings. Full `swift test --skip-build`: 2637 tests in 277 suites passed, 1 known issue (HarnessSmokeTests, there before). TranscriptSearchGoldenTests passed. The first full run had a 60 second time limit failure in two ScheduledAgentEndToEndTests tests; the second full run passed; a loop showed the same suite fails without a shutdown too. New task 01M7TKANKV98J2TX1456YQBVX6 records that flake.
    - next: review
  timestamp: 2026-11-19T19:08:19.238949+00:00
- actor: claude-code
  id: 01m7tknn5mbyj5385xr32nkbk7
  text: |-
    ### review — clean
    - evidence: review sha b8b204f~1..b8b204f: 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed. 5 files reviewed.
    - next: none. The task is in done.
  timestamp: 2026-11-19T19:13:55.892076+00:00
position_column: done
position_ordinal: ffffffa680
title: The item ids of the transcript search can collide for a session id with a "/"
---
Found during ^bm6spcd.

## Current behavior

`TranscriptSearchItem.id` is `<session id>/<ordinal>` for a chunk item, and the session id for a session item. Now a session id of the index can be any string (^bm6spcd). A session id that holds a "/" can give the id of an item of another session: the session item of the session `a/1` and the chunk item 1 of the session `a` both have the id `a/1`. The catalog then keeps only one of the two items.

UUID session ids hold no "/", so Claude Code and Codex do not cause it now. A free-form ACP session id can.

## Change

Make the item ids unique for each session id string. For example, escape the "/" in the session id part, or give the session item a fixed suffix. A change of the id form changes the stored catalog, so the load must drop or convert an old catalog.

## Tests

- Two sessions `a` and `a/1`, each with a chunk: the index keeps each item, and a search finds each session.
- A stored catalog of the old form still loads.

#search #d207
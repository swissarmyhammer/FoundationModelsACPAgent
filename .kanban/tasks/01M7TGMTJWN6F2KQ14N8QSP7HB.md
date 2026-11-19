---
assignees:
- claude-code
position_column: todo
position_ordinal: '9780'
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
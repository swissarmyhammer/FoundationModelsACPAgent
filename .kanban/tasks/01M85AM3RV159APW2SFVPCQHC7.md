---
position_column: todo
position_ordinal: '81'
title: 'D212 5.2: search items for the typed external sessions'
---
Request from TestudoApp (testudoapp-9a, 2026-11-23). Testudo card ^shyf0hd waits for it.

Design: TestudoApp/features/session-import-redesign.md sections 5.2 and 6 (the FoundationModelsACPAgent row), and the searcher of D207 (b).

Work:
- The transcript searcher of the agent gets one item for each typed external session of the index, with the id `external:<source>/<id>` and the block of the index fields (title, first prompt, last prompt, folder, branch, dates).
- No item for an automated session, so the embedder does not embed 28,000 items.
- The items follow the index: a read adds or changes an item, a file that is gone removes its item, and a removed root removes the items of the root.
- No item reads a session file: the items use only the index.

Tests: an item for each typed session and none for an automated session; a change of the index changes the item; a removed root removes the items.

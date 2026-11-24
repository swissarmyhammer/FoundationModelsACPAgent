---
comments:
- actor: claude-code
  id: 01m85ej1w6p5rrvcgjycefsqwb
  text: |-
    ### implement — done

    - Multitool 4af672b3: `SessionSearchPage.externalSessions: [ExternalSessionSearchResult]` (session, score, field). GraphQL `SessionSearchConnection.externalSessions`. The `search sessions` operation gives one line for each external session. Skill 1.12.0.
    - The search index keeps one external item for each typed session in the state `read`, with the id `external:<source>/<id>` and the block of the index fields. An automated session gets no item. No item reads a session file.
    - The items follow `externalSessionChanges(folder: nil)`. An element with no session makes the items again from `ExternalSessionIndex.typedReadSessions()`, which reads only memory. The shutdown stops the follow.
    - The first page of a search with no session filter gives at most 20 external results. A later page and a search with a `sessions` or `session` filter give none.
    - Tests: `TranscriptSearchExternalTests`, 9 cases. Each key line was undone, and a test then failed.
  timestamp: 2026-11-24T00:16:13.000000+00:00
position_column: done
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

---
assignees:
- claude-code
position_column: todo
position_ordinal: '9480'
title: 'D207: the client transcript search index accepts any session id, not only a ULID'
---
Gap from the TestudoApp search work (2026-11-19).

## Current behavior

`TranscriptSearchIndex.search` gives back only sessions whose ids are ULIDs. The app's CLIENT index (`<AgentHome.local>/session-search/client/`) holds the sessions of other ACP agents, for example Claude Code, whose session ids are UUIDs or other strings. Those sessions never come back from a search.

## Change

1. The index accepts any session id string (the ACP `SessionId`). Keep the ULID rule only where the server needs it (for example where the agent maps a hit to a Router session, or where Multitool's `SessionSearchResult.session` is a `ULID`).
2. If a public type (for example a result type) carries a `ULID` where the client needs a string, add a string form for the client path, and say which types change. Do not break the Multitool protocol: the server searcher still gives ULIDs to Multitool.
3. Keep the ordering, filters, snippets and cursor the same.

## Dependency

Do this after ^w0dheny (the search speed task), because both change the search code.

## Tests

- A client index with a UUID session id and a free-form session id: a search returns them, with their hits and snippets.
- The server searcher still returns ULID sessions to Multitool, and the results are the same as before.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d207 #search
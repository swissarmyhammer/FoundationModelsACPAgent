---
depends_on:
- 01M85AM3RYBJVFYPY3459HP4FY
position_column: todo
position_ordinal: '85'
title: 'D212 5.6: the counts of the automated sessions of a folder and of a root'
---
Request from TestudoApp (testudoapp-9a, 2026-11-23). Design: section 5.6 (the Settings pane: "126 sessions, 28,131 automated sessions").

Work:
- A count of the typed and of the automated sessions, for each root and for one folder, with no paging: from the index in memory, with no walk of the entries when possible (keep counts in the root, as the counts of each project key).
- On the endpoint: for example fields `typedCount` and `automatedCount` on the page, or a query `externalSessionCounts(source:, folder:)`.

Tests: the counts of a store with typed and automated sessions, for a root and for a folder, and after a change.

---
depends_on:
- 01M85AM3RYBJVFYPY3459HP4FY
position_column: done
position_ordinal: '85'
title: 'D212 5.6: the counts of the automated sessions of a folder and of a root'
comments:
- actor: claude-code
  id: 01m85am3s0m4x4pgake1wcdone
  text: 'Done. ACPAgent 24a6c76: externalSessionCounts(source:folder:) from the totals of each root, or from the entries in memory for one folder. Multitool 09e462c2: the query externalSessionCounts and the tool operation count external sessions. Extras 3742dff: ExternalSessionCounts.'
  timestamp: 2026-11-24T01:11:31.953065+00:00
---
Request from TestudoApp (testudoapp-9a, 2026-11-23). Design: section 5.6 (the Settings pane: "126 sessions, 28,131 automated sessions").

Work:
- A count of the typed and of the automated sessions, for each root and for one folder, with no paging: from the index in memory, with no walk of the entries when possible (keep counts in the root, as the counts of each project key).
- On the endpoint: for example fields `typedCount` and `automatedCount` on the page, or a query `externalSessionCounts(source:, folder:)`.

Tests: the counts of a store with typed and automated sessions, for a root and for a folder, and after a change.

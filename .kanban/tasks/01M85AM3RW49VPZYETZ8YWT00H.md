---
depends_on:
- 01M85AM3RV159APW2SFVPCQHC7
position_column: todo
position_ordinal: '82'
title: 'D212 5.6: rebuild the index of external sessions (endpoint mutation and tool operation)'
---
Request from TestudoApp (testudoapp-9a, 2026-11-23). Design: section 5.6 and 5.7 (the command Rebuild Index of <source> Sessions).

Work:
- ExternalSessionIndex: a rebuild of one source: the index file of the source is removed, the entries go, and a new find and build start. The old rows go to the subscribers as removed, and the new rows come as the build reads them.
- FoundationModelsExtras: the host protocol gets the rebuild call (brief foundationmodelsextras-ef).
- FoundationModelsMultitool: the mutation `rebuildExternalSessionIndex(source:)` and the tool operation `rebuild external session index`.

Tests: a rebuild reads each file again and gives the same rows; a rebuild of a source with no access gives sourceUnreadable.

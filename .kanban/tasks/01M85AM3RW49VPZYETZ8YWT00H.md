---
depends_on:
- 01M85AM3RV159APW2SFVPCQHC7
position_column: done
position_ordinal: '82'
title: 'D212 5.6: rebuild the index of external sessions (endpoint mutation and tool operation)'
comments:
- actor: claude-code
  id: 01m85am3rw49vpzyetz8ywdone
  text: 'Done. ACPAgent 24a6c76: ExternalSessionIndex.rebuild(_:) and the host call rebuildExternalSessionIndex(source:). Multitool 6da9737e: the mutation rebuildExternalSessionIndex(input: {source}) and the tool operation rebuild external session index. Extras 3742dff: the host call.'
  timestamp: 2026-11-24T01:11:31.953065+00:00
---
Request from TestudoApp (testudoapp-9a, 2026-11-23). Design: section 5.6 and 5.7 (the command Rebuild Index of <source> Sessions).

Work:
- ExternalSessionIndex: a rebuild of one source: the index file of the source is removed, the entries go, and a new find and build start. The old rows go to the subscribers as removed, and the new rows come as the build reads them.
- FoundationModelsExtras: the host protocol gets the rebuild call (brief foundationmodelsextras-ef).
- FoundationModelsMultitool: the mutation `rebuildExternalSessionIndex(source:)` and the tool operation `rebuild external session index`.

Tests: a rebuild reads each file again and gives the same rows; a rebuild of a source with no access gives sourceUnreadable.

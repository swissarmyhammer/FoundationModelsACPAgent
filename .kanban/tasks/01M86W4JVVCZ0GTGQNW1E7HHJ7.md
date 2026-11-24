---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: 'Search rows of external sessions: give the file and the continued sessions'
---
## Problem

Brief: .briefs/FoundationModelsACPAgent-search-external-fields-2026-11-24.md.

The transcript search index stores the external summaries with no decoration. Thus each row of `SessionSearchPage.externalSessions` has `fileURL == nil` and `continuedSessions == []`. The Search row of Testudo has no Show Source File and no "Continued" line.

## Fix

`searchTranscripts` decorates the external rows of the page with `AgentSessionImporter.decorated(_:)` before the page goes to the client (option A of the brief). A new copy shows at once, with no new item in the index.

## Test

A search that matches an external session gives its file in the root. After a continue, the same search gives the copy in `continuedSessions`.
## Result

ACPAgent 846e353. `searchTranscripts` decorates the external rows of the page with `AgentSessionImporter.decorated(_:)`. Test: `theSearchRowOfTheSourceGivesItsFileAndItsCopy`. It failed before the fix.

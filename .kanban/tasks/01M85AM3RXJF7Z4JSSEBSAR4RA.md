---
depends_on:
- 01M85AM3RW49VPZYETZ8YWT00H
position_column: todo
position_ordinal: '83'
title: 'D212 Q85: the earlier copies of an external session on ExternalSession'
---
Request from TestudoApp (testudoapp-9a, 2026-11-23). Design: section 5.4 (the header text "Continued <date> as @<short id>").

Work:
- ExternalSession (Multitool GraphQL) and the summary of the host get the earlier copies of the session: for example `continuedSessions { id createdAt }`, from the provenance of the sessions of the directory (SessionSummary.importedFrom).
- Each continue adds a copy; the field shows each copy, the oldest first.

Tests: a session with two copies shows both; a session with no copy shows none.

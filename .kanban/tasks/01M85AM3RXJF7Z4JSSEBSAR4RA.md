---
depends_on:
- 01M85AM3RW49VPZYETZ8YWT00H
position_column: done
position_ordinal: '83'
title: 'D212 Q85: the earlier copies of an external session on ExternalSession'
comments:
- actor: claude-code
  id: 01m85am3rxjf7z4jssebsadone
  text: 'Done. ACPAgent 1cdb294: ExternalSessionContinuations gives continuedSessions on each page and change. Multitool a6f6a0e6: ExternalSession.continuedSessions { id createdAt }. Extras 3742dff: ExternalSessionContinuation.'
  timestamp: 2026-11-24T01:11:31.953065+00:00
---
Request from TestudoApp (testudoapp-9a, 2026-11-23). Design: section 5.4 (the header text "Continued <date> as @<short id>").

Work:
- ExternalSession (Multitool GraphQL) and the summary of the host get the earlier copies of the session: for example `continuedSessions { id createdAt }`, from the provenance of the sessions of the directory (SessionSummary.importedFrom).
- Each continue adds a copy; the field shows each copy, the oldest first.

Tests: a session with two copies shows both; a session with no copy shows none.

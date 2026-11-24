---
depends_on:
- 01M85AM3RXJF7Z4JSSEBSAR4RA
position_column: done
position_ordinal: '84'
title: 'D212 5.3: the absolute file path of an external session'
comments:
- actor: claude-code
  id: 01m85am3rybjvfypy3459hdone
  text: 'Done. ACPAgent 1cdb294: fileURL is the resolved root plus the path; a path outside the root gives nil. Multitool 255d7c8e: ExternalSession.filePath. Extras 3742dff: ExternalSessionSummary.fileURL.'
  timestamp: 2026-11-24T01:11:31.953065+00:00
---
Request from TestudoApp (testudoapp-9a, 2026-11-23). Design: section 5.7 (Show Source File in Finder).

Work:
- ExternalSession gets the absolute path of its file (root + path), so the app can show the file in Finder within its grant.
- Check that the path is in the root that the host gave (no path outside the grant).

Tests: the path is the root plus the relative path, also for a root with a symbolic link.

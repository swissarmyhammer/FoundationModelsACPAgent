---
depends_on:
- 01M85AM3RXJF7Z4JSSEBSAR4RA
position_column: todo
position_ordinal: '84'
title: 'D212 5.3: the absolute file path of an external session'
---
Request from TestudoApp (testudoapp-9a, 2026-11-23). Design: section 5.7 (Show Source File in Finder).

Work:
- ExternalSession gets the absolute path of its file (root + path), so the app can show the file in Finder within its grant.
- Check that the path is in the root that the host gave (no path outside the grant).

Tests: the path is the root plus the relative path, also for a root with a symbolic link.

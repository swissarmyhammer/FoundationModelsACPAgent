---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: 'Content catalog (e): the external sessions part (D214)'
---
## Problem

Brief: .briefs/FoundationModelsACPAgent-spotlight-content-catalog-2026-11-24.md, part 5. The host has no read of the typed external sessions for Spotlight.

## Fix

- `ExternalSessionContentRecord`: id, name (title, else first prompt, else last prompt), cwd, gitBranch, firstPrompt, lastPrompt, firstDate, lastDate, modified.
- `ExternalSessionContentCatalog` (`contentCatalog.externalSessions`): `stamps()`, `records(of:)`, `record(_:)`, `changes()`. A domain is one source agent. The records are the typed entries in the state `read`. An automated entry has no record.
- The stream: a typed entry gives `changed`. An entry that became automated, or whose file is gone, gives `removed`. A removed root gives `domainRemoved`. The index event now names its removed sources (`removedSources`), so the stream has no race with the root change.

## Tests

`ExternalContentCatalogTests`: a typed session gives a record and a stamp; an entry that becomes automated gives `removed`; Remove Access gives `domainRemoved`.
## Result

Done as planned. The full suite passed (2866 tests, 1 known issue).

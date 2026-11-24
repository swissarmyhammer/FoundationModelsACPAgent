---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: 'Content catalog (a): the sessions part, and the ContentCatalog value (D214)'
---
## Problem

Brief: .briefs/FoundationModelsACPAgent-spotlight-content-catalog-2026-11-24.md, part 1. The host has no read of the sessions of the server for Spotlight.

## Fix

- `ContentCatalog` on `RoutedACPAgent` and `ComposedAgent` (`contentCatalog`), with `sessions` and `turns`. The later parts add a property each.
- `ContentCatalogChange<Domain, Record>`: `changed`, `removed`, `domainRemoved`.
- `SessionContentRecord`: id, shortID, slug, name, folder, tags (sorted), agentName, kind, origin, createdAt, lastUsedAt, archivedAt, isPinned, recap, lastSummary.
- `SessionContentCatalog`: `stamps()`, `records(of:)`, `record(_:)`, `changes()`. It reads only the folders that `readableFolder` permits. The stream maps the events of the session directory, and `session/delete` publishes `domainRemoved` for each removed session (`contentRemovalFeed`).

## Tests

`SessionContentCatalogTests`: a tag gives a record with the tag and a new stamp; a refused folder gives no record; a rename gives a change with the new name; a delete gives `domainRemoved`.
## Result

Done as planned. The full suite passed (2862 tests, 1 known issue).

---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: 'Content catalog (c): the boards part, a seam, and the KanbanHost adapter (D214)'
---
## Problem

Brief: .briefs/FoundationModelsACPAgent-spotlight-content-catalog-2026-11-24.md, part 3. The host has no read of the boards and tasks of the known folders for Spotlight. The library does not link FoundationModelsKanban (Package.swift).

## Fix

- Library: the seam `BoardContentSource` (stamp, board, changes of a folder), the neutral records `BoardContentRecord`, `BoardColumnSummary`, `TaskContentRecord`, `TaskContentID`, `TaskDependency`, and `BoardContentCatalog` (`contentCatalog.boards`): `stamps()`, `records(of:)`, `board(of:)`, `record(_:)`, `changes()`. The known folders are the folders of the sessions that `readableFolder` permits, and the folder of each session that starts later.
- `useBoardContentSource(_:)` on RoutedACPAgent and ComposedAgent.
- The `acp-agent` composition target (it links Kanban already) has the adapter `KanbanBoardContentSource` over `KanbanHost.shared`, and the composition gives it. No new target or product (user rule); Testudo's way to get the adapter is a user decision.
- FoundationModelsKanban moves to c8e0ec4 in Package.resolved.

## Tests

`BoardContentCatalogTests`: the seam reads and maps changed tasks, removed tasks and a removed board; a refused folder gives no record; the adapter over the real host gives the task of a write of another session and the id of a delete.
---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: A failed registry build leaves the MCP servers of the session connected
---
Found on 2026-11-21 during ^2zm9hbk.

## Facts

- `ToolCatalog.composeRest` (ToolCatalog.swift) connects the MCP servers (`MCPComposition.connectServers`), calls `builder.withMCP(servers:)`, adds the server processes to `builder.serverPool`, and then calls `composeCodeContext` and `builder.buildRegistry()`.
- When `withMCP`, `composeCodeContext` or `buildRegistry` throws, `makeRegistry` releases only the shell store lease (and `composeRest` releases the code-context lease). Nothing shuts down the server pool, and nothing disconnects the connected servers or stops their processes.

## Work

- [ ] Shut down the connected MCP servers and their processes on each error path of `makeRegistry` after `connectServers`.

## Tests

- [ ] A test shows that a failed registry build stops the MCP servers that it connected.
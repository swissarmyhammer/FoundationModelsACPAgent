---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: The initialize capabilities advertise mcp.stdio in sandboxed mode
---
## What
`RoutedACPAgent.advertisedCapabilities` (Sources/FoundationModelsACPAgent/Agent/Initialization.swift) is static. It always advertises `session.mcp.stdio`. After ^xfeamnv, an agent in `sandboxed` tool mode refuses each stdio MCP server (`MCPComposition.Refusal.stdioInSandboxedMode`). A client can thus send a stdio server that the agent always refuses.

Decide with testudoapp-75 if the `initialize` result of a `sandboxed` agent must omit `mcp.stdio`. If yes, make the capabilities read `toolMode`.

## Acceptance Criteria
- [ ] The decision is recorded on this task.
- [ ] If the decision is to omit it: a `sandboxed` agent advertises `mcp.http` only, and an `open` agent advertises both.

## Tests
- [ ] InitializationTests: the `mcp` capability for each `ToolMode`.
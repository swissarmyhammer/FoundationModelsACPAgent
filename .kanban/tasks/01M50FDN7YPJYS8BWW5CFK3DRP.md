---
assignees:
- claude-code
position_column: done
position_ordinal: ffde80
title: MCP servers of a session get the user presence of the session
---
Step lead request, elicitation phase 2. Start it only when the step lead gives the Multitool head with `MCPServer(..., userPresence:)` (Multitool task 24).

Work:
- Add userPresence to CatalogContext. composeSession sets it from the client capabilities, at session/new and at session/resume: the same value as the Router session (RoutedACPAgent.userPresence).
- Pass it through MCPComposition.connectServers to MCPServer(name:userPresence:).
- ToolsProber.startMCPServer passes .headless.
- Move the Multitool pin (root and IntegrationTests).

Test (fixed order, fails on the old code): the MCP server of a headless session advertises no elicitation capability; the MCP server of an interactive session advertises form and URL.

Rules: one full run, IntegrationTests build, commit, push when green. #elicitation-phase-2
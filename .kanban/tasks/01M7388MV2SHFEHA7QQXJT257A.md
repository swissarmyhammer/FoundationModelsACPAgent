---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m738ec2rsmdvm09h2qb8htrq
  text: 'Changes (2026-11-10): testudoapp-75 put this card in step1 (a hang of the session composition in OpenTestudo is a real defect). foundationmodelsmultitool-2a asks: (1) send it the exact cause if the wait is in `StdioServerProcess` or `MCPServer.connect` (Multitool); it then makes a Multitool card with a regression test; (2) a test for it must NOT depend on time. Thus replace the "under 5 seconds" criterion: the test waits for the composition to end (for example with a gated process or an exit signal), not for a clock. The criterion is: `session/new` ends, and the server shows as failed. For the server that never answers, a time limit constant is still the product rule, but the test gives a short injected limit or a fake clock.'
  timestamp: 2026-11-10T17:35:10.936034+00:00
position_column: todo
position_ordinal: 8b80
title: A config stdio MCP server that exits before it answers must not make session/new wait
---
## What
Found on 2026-11-10 during ^xfeamnv. A test marker script ran `touch` and then exited. In `open` mode the session composition waited for that config stdio server to answer the MCP `initialize`, and it did not stop when the process exited. The test run hung for more than 15 minutes. Thus a real config stdio server that crashes at start can make `session/new` wait for a long time.

1. Reproduce it in a test: a config `mcp:` stdio entry whose command exits at once with code 0, and one that exits with code 1.
2. Find where the wait is: `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift` (`connectServers`) and the Multitool `StdioServerProcess` / MCP client connect. If the cause is in FoundationModelsMultitool, do not edit that repository: report the exact cause to session foundationmodelsmultitool-2a and make this task depend on its commit.
3. The connect must end when the process exits before the handshake: record one failure for that server (the same record as other MCP connect failures, so `session/new` still succeeds and the server shows as failed), and go on with the other servers.
4. Confirm that a connect time limit exists for a server that stays alive and never answers. If there is none, add one with a named constant.

## Acceptance Criteria
- [ ] `session/new` with a stdio server that exits at once returns within a short time (for example under 5 seconds in the test), and the server shows as failed.
- [ ] The other MCP servers of the session still connect.
- [ ] A server that never answers fails at the time limit.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift`: the three cases above, with a time limit on each test.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1
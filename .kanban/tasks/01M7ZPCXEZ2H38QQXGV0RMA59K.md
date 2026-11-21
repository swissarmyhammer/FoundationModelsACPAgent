---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7zq4djcx7qj0gmbkz2wp9c9
  text: |-
    ### implement — changed
    - evidence: 5 files.
      - Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift: `makeRegistry` now fills a `StartedSessionParts` (the shell store lease and the server pool of the builder) and calls `stop()` on each error after `composeShell`. `composeRest` puts each connected server and each server process into the pool before `withMCP(servers:)`, so a failure of `withMCP`, `composeCodeContext` or `buildRegistry` shuts them down. It adds the code-context lease to the parts, so the separate catch around `buildRegistry` was removed.
      - Sources/FoundationModelsACPAgent/Tools/StartedSessionParts.swift: the doc names `makeRegistry` as a user.
      - Tests/FoundationModelsACPAgentTests/FailedRegistryBuildTests.swift (new): open mode with a sandboxed probe. A stdio server (`/bin/sh -c 'echo $$ > pidfile; exec mcp-test-server --mode echo'`) connects, then `buildRegistry()` throws `openModeInSandbox`. The test waits for the exit of the server process.
      - Tests/FoundationModelsACPAgentTests/Support/ProcessExitWatch.swift: a cancel (for example the time limit) now ends the wait with `false` (`@discardableResult`). Without this, the RED run did not end: the wait ignored the time limit.
    - Other error paths of `makeRegistry`: `composeShell` throws before it holds a lease. `connectServers` does not throw, and it shuts down a server that fails to connect. `composeCodeContext` releases its own lease when it fails. No other part starts work.
    - RED: "Time limit was exceeded: 60.000 seconds" and "Expectation failed: exited". GREEN: FailedRegistryBuildTests, MCPCompositionTests, ShellStoreSharingTests and FailedSessionSurfaceTests gave 39 passes. Full root `swift test --skip-build` after "Build complete!": 2758 tests in 294 suites passed, 0 failures (1 known issue, from an earlier test).
    - next: /review.
  timestamp: 2026-11-21T18:50:37.516250+00:00
position_column: doing
position_ordinal: '80'
title: A failed registry build leaves the MCP servers of the session connected
---
Found on 2026-11-21 during ^2zm9hbk.

## Facts

- `ToolCatalog.composeRest` (ToolCatalog.swift) connects the MCP servers (`MCPComposition.connectServers`), calls `builder.withMCP(servers:)`, adds the server processes to `builder.serverPool`, and then calls `composeCodeContext` and `builder.buildRegistry()`.
- When `withMCP`, `composeCodeContext` or `buildRegistry` throws, `makeRegistry` releases only the shell store lease (and `composeRest` releases the code-context lease). Nothing shuts down the server pool, and nothing disconnects the connected servers or stops their processes.

## Work

- [x] Shut down the connected MCP servers and their processes on each error path of `makeRegistry` after `connectServers`.

## Tests

- [x] A test shows that a failed registry build stops the MCP servers that it connected.
---
assignees:
- claude-code
depends_on:
- 01KYSV76CBJV66C92Z0EM2S73K
position_column: todo
position_ordinal: '8880'
title: 'MCP composition: config servers, client mcpServers, server pool, surface refresh'
---
## What
Plan.md §7.3, §11.2, §11.5. Create `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift`.

Compose two sources into `withMCP(servers:)`: the config-derived `mcp:` servers first, then the client-supplied per-session `mcpServers`. The client list is session scope and is **never persisted**; `session/resume` re-supplies it.

**The MCP API changed. These are the facts as of 2026-08-31:**

- **`withMCP(servers: [MCPServer]) async throws -> Self`** takes `MCPServer` actors, not plain server descriptions.
- `MCPServer(name:version:clock:callTimeout:renderBudget:elicitationHandler:logger:)` — everything but `name` has a default. Connect with `connect(via: any Transport)` or `connect(via: @escaping TransportFactory)`, each also taking a `BackoffPolicy`. Then `waitUntilReady()`. Also available: `reconnect()`, `disconnect()`, `call(name:arguments:)`.
- `MCPServerState` is `connecting`, `ready`, `disconnected`, `faulted(String)`. `ServerIdentity` is only `{ name: String }`. ACP's `name` maps to `MCPServer.name`.
- **The server name is the noun.** A tool is `tools.github.createIssue`, never `tools.mcp.github.createIssue`. There is no `tools.mcp` group. The model must not see the transport.
- Stdio: `StdioServerProcess(command:args:env:name:) throws`. **The command must be an absolute path**, enforced with a `hasPrefix("/")` guard. `EnvVariable {name, value}` layers onto the inherited environment and never replaces it. The process has **`respawn() async throws -> any Transport`** and **`shutdown() async`** — both are `async`.
- HTTP: an `MCP.Transport` conformer built from the ACP `headers`. `env` and `headers` are arrays of `{name, value}`; for duplicate names, last wins. No SSE. The ACP tunnel (`mcp/connect`) is unstable-schema only. Do not build it.
- **Connect before `buildRegistry()`.** Router's tool-instancing pipeline is synchronous. Expose an async `connect` step that session/new awaits.
- **Hold the servers in a pool.** `MCPServerPool` is an actor with `add(server:)`, `add(process:)`, `attach(attachment:)` and `shutdownAll()`. `Builder.serverPool` already holds every server that `withMCP(servers:)` recorded. Add each `StdioServerProcess` we spawned. The lifecycle task shuts it down after the session sweep.
- **Refresh the surface with `SurfaceRefresher(source:staging:servers:logger:)`.** Get `source` from `Builder.registrySource` and `staging` from `Registry.makeSessionToolsAndStaging(librarian:)`. The staged registry is applied at `MultiTool.turnWillBegin()`, so in-flight runs keep the registry they started with.
  **It does NOT watch `tools/list_changed` directly.** It consumes each server's `catalogUpdates` stream, which also fires when a connect reaches `.ready` and when a connect fails after an earlier success. So expect a rebuild on a reconnect, not only on a re-list, and make the rebuild idempotent and cheap.
  **It asserts in `deinit` if it is released while its watch task runs**, so attach it to the pool or call `stop()`.
- An MCP verb is a plain synchronous `Tool`. It does not background. A transport drop makes the in-flight call throw `MCPServerError.lost(...)`, which conforms to Router's `LostRunError`, and Router's run machinery settles the run `.lost` — never `.failed`.

**Decide and document the §7.3 collision rule.** Recommended: refuse a client-supplied server whose name collides with a config-derived server, and log the error. Config is the user's committed intent, and a silent replacement would let a connecting editor shadow a trusted server. Record the decision in a doc comment and in plan.md §7.3.

`mcp: false` turns MCP fully off AND refuses client-supplied servers with a logged reason.

**The elicitation fallback is gone. Do not build it.** The old task asked for a coordinator conforming to Multitool's `ElicitationCoordinator`. That protocol and `MCPElicitationTool` were deleted upstream. The current seam is `MCPServer.ElicitationHandler`, and the answering order is: the `ToolContext` of the calling run through Router's mailbox, then the host's `elicitationHandler`, then `cancel` to the server. The source comment says it outright — "Router wins when present, so a Router host never sets the handler." We are a Router host, so **leave `elicitationHandler` nil**. Our seam is `RoutedSession.respond(elicitationId:response:)` and `RoutedSession.complete(elicitationId:)`. Note the `ToolContext` binding applies only when exactly one call is in flight. Elicitation is not the permission system.

- [ ] Two-source composition, config first
- [ ] Collision rule decided and documented
- [ ] Connect and `waitUntilReady()` before `buildRegistry()`
- [ ] Servers and spawned processes added to `MCPServerPool`
- [ ] `SurfaceRefresher` started and attached so it is stopped
- [ ] Rebuild is idempotent, because reconnects trigger it too
- [ ] `mcp: false` refuses client servers with a log
- [ ] `elicitationHandler` left nil

## Acceptance Criteria
- [ ] Given config servers A and B and client server C, the noun order is A, B, C
- [ ] A client server named A is refused per the documented rule, and the session still starts
- [ ] With `mcp: false`, client-supplied servers give zero tools and one logged refusal
- [ ] A server's tools appear as `tools.<serverName>.<verb>`, with no `mcp` segment
- [ ] A relative command path to `StdioServerProcess` throws rather than spawning
- [ ] A `tools/list_changed` from a scripted server stages a new registry, and the new tool appears only at the next turn boundary
- [ ] A reconnect also stages a rebuild, and it changes nothing when the catalog is unchanged
- [ ] Nothing about client servers appears in `sessions.jsonl`
- [ ] Releasing the composition does not trip the `SurfaceRefresher` deinit assertion

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift` — composition, collision and refusal driven by the `MCPTestServer` library's `ScriptedServer` and the `mcp-test-server` executable that Multitool ships
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fm3cbh6c9fn1yfvyj4z3g8
  text: |-
    Research results (from ../FoundationModelsMultitool and this repository):

    - `MCPServer` actor: `init(name:version:clock:callTimeout:renderBudget:elicitationHandler:logger:)`. Connect calls: `connect(via: any Transport)`, `connect(via: TransportFactory)`, each also with a `BackoffPolicy` variant. `waitUntilReady()`, `reconnect()`, `disconnect()`, `call(name:arguments:)`. `elicitationHandler` is internal, so a test cannot read it. We do not pass it, and a doc comment records the rule.
    - `MCPServerPool` actor: `add(server:)`, `add(process:)`, `attach(attachment:)`, `shutdownAll()`. `Builder.serverPool` holds each server that `withMCP(servers:)` recorded. `withMCP(servers:)` needs servers that are already connected (`MCPCapability.init(server:)` reads the catalog).
    - `SurfaceRefresher(source:staging:servers:logger:)` + `start()`. `MCPServerPool.shutdownAll()` stops an attached refresher first. The `deinit` assertion trips only when the watch task still runs. The refresher rebuilds on the first snapshot of each server, and it does not stage when `snapshot.diff(from: previous).isEmpty` — this is the unchanged-catalog no-op.
    - `StdioServerProcess(command:args:env:name:) throws` — `hasPrefix("/")` guard throws `commandNotAbsolute`. `respawn()` is the transport factory. `shutdown()` is async. `env` layers onto the inherited environment; a later repeated name wins.
    - HTTP transport: `HTTPClientTransport(endpoint:configuration:)` from the `MCP` module (swissarmyhammer/swift-sdk fork). Our manifest must declare that package with the same URL Multitool uses: `https://github.com/swissarmyhammer/swift-sdk.git`, branch `main`.
    - ACP wire types: `FoundationModelsACP.MCPServer` enum with `.stdio(MCPServerStdio)`, `.http(MCPServerHTTP)`, `.unknown`. Name collision with Multitool's `MCPServer` actor — code must qualify by module.
    - Test support: Multitool ships the `MCPTestServer` library product (`ScriptedServer`, `ServerMode`, `LoopbackHTTPServer`) and the `mcp-test-server` executable product. Multitool's own manifest says a test target cannot depend on an executable; their unit tests find the binary beside the test bundle because `swift test` builds every target of the same package. For our package, an experiment must show if a cross-package executable product dependency is possible; the fallback is a small local `.executableTarget` over the shipped `MCPTestServer` library with the same `main.swift` shape.
    - `MultiTool.call(arguments: RunCodeArguments)` and `MultiTool.turnWillBegin()` are public — a test can read the mounted surface with a `help()` snippet and drive the turn boundary by hand, as the upstream `SurfaceRefresherTests` does.
    - `ToolCatalog.sessionTools(context:)` mounts with `makeSessionTools` today and drops the staging. The composition needs `makeSessionToolsAndStaging(librarian:)`, the refresher, and the pool. The mount entry must return the pool, so the plan is a `SessionSurface { tools, serverPool }` value.
    - `SessionIndex` has a fixed field set and no MCP field; plan.md line comment already forbids `mcpServers` in `sessions.jsonl`.
    - Config side is complete: `MCPToolSection` (.disabled / .enabled(servers:)) and `MCPServerConfiguration` (.stdio / .http) in ToolSectionCodec.swift.
  timestamp: 2026-09-01T23:15:35.921203+00:00
- actor: claude-code
  id: 01m1fmxct0mjdtr4p92hcgb8y6
  text: |-
    Implementation landed, TDD order (failing suite first, then the code):

    - New `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift`: `composeRoster` (config first, then client; collision and mcp-disabled refusals; env/header pair normalization with last-wins), `connectServers` (connects each entry, `waitUntilReady()`, spawns `StdioServerProcess` for stdio, `HTTPClientTransport` factory for http, cleanup on a partial failure), `startSurfaceRefresher` (starts and attaches to the pool; no refresher when there is no server). `elicitationHandler` is never passed. The collision rule is in the type doc comment and in plan.md §7.3.
    - `ToolCatalog`: `makeRegistry(context:)` is now async and returns `BuiltRegistry { registry, source, pool, mcpServers }`; the public mount entry is `sessionSurface(context:) -> SessionSurface { tools, serverPool }`. `sessionTools` is replaced, because a session with MCP servers must get the pool for `shutdownAll()`.
    - `CatalogContext` gains `clientMCPServers: [FoundationModelsACP.MCPServer] = []`.
    - `Package.swift`: declares the swift-sdk fork (`https://github.com/swissarmyhammer/swift-sdk.git`, the URL Multitool uses) and links `MCP` in the library; the test target links Multitool's `MCPTestServer` library product and the `mcp-test-server` executable product. The executable-product dependency works cross-package, so `swift test` builds the binary beside the test bundle.
    - Tests: `MCPCompositionTests.swift` (13 cases — roster order, collisions, disabled refusal, unknown transport, env/header normalization, relative-command throw, bad-url throw, mounted noun order with three spawned `mcp-test-server` subprocesses, list_changed staged and applied only at `turnWillBegin()`, reconnect rebuild + unchanged no-op with pool `shutdownAll()`, `SessionIndexRecord` key set) and `MCPTestServerLocator.swift` (a port of Multitool's locator).
    - Discovery for the next agent: `swift build --product mcp-test-server` also works from this package root; a cross-package executable product IS a legal test-target dependency on this toolchain.
    - Also fixed a pre-existing `#require` redundancy warning in `TranscriptStoreTests` to keep the run at zero warnings.
    - plan.md: §7.3 records the decided collision rule; the §11.1 sketch now shows `sessionSurface`.

    ### implement — changed
    - evidence: 10 files — Package.swift, Sources/.../Tools/MCPComposition.swift (new), Sources/.../Tools/ToolCatalog.swift, Sources/.../Tools/CatalogContext.swift, Tests/.../MCPCompositionTests.swift (new), Tests/.../MCPTestServerLocator.swift (new), Tests/.../ToolCatalogTests.swift, Tests/.../TranscriptStoreTests.swift, plan.md, .kanban
    - next: test
  timestamp: 2026-09-01T23:29:48.352230+00:00
- actor: claude-code
  id: 01m1fn2r2m1ybfw8s2xb7jysc6
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings (0 confirmed, 0 refuted), 8 files reviewed; .kanban and plan.md excluded by rule
    - next: done
  timestamp: 2026-09-01T23:32:43.732077+00:00
- actor: claude-code
  id: 01m1fn2zc7fs5sem6pkzn02103
  text: |-
    ### finish iteration 1 — done
    - implement: changed (10 files — MCPComposition.swift, ToolCatalog.swift, CatalogContext.swift, Package.swift, plan.md, MCPCompositionTests.swift, MCPTestServerLocator.swift, ToolCatalogTests.swift, TranscriptStoreTests.swift, .kanban)
    - test: green (swift test — 126 tests in 14 suites passed, 0 failed, 0 skipped, 0 warnings)
    - commit: 2600fa3
    - review: clean (review sha HEAD~1..HEAD — 0 findings, 8 files reviewed)
  timestamp: 2026-09-01T23:32:51.207035+00:00
depends_on:
- 01KYSV76CBJV66C92Z0EM2S73K
position_column: done
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

- [x] Two-source composition, config first
- [x] Collision rule decided and documented
- [x] Connect and `waitUntilReady()` before `buildRegistry()`
- [x] Servers and spawned processes added to `MCPServerPool`
- [x] `SurfaceRefresher` started and attached so it is stopped
- [x] Rebuild is idempotent, because reconnects trigger it too
- [x] `mcp: false` refuses client servers with a log
- [x] `elicitationHandler` left nil

## Acceptance Criteria
- [x] Given config servers A and B and client server C, the noun order is A, B, C
- [x] A client server named A is refused per the documented rule, and the session still starts
- [x] With `mcp: false`, client-supplied servers give zero tools and one logged refusal
- [x] A server's tools appear as `tools.<serverName>.<verb>`, with no `mcp` segment
- [x] A relative command path to `StdioServerProcess` throws rather than spawning
- [x] A `tools/list_changed` from a scripted server stages a new registry, and the new tool appears only at the next turn boundary
- [x] A reconnect also stages a rebuild, and it changes nothing when the catalog is unchanged
- [x] Nothing about client servers appears in `sessions.jsonl`
- [x] Releasing the composition does not trip the `SurfaceRefresher` deinit assertion

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift` — composition, collision and refusal driven by the `MCPTestServer` library's `ScriptedServer` and the `mcp-test-server` executable that Multitool ships
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
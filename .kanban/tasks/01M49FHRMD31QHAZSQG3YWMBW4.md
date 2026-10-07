---
comments:
- actor: claude-code
  id: 01m4bkwzqxm40abt6g1wsr83me
  text: |-
    Research done.
    - `SessionSurface` is public, but `MCPComposition` is internal. Thus `mcpServerOutcomes` is an internal stored property. The public init stays and gives an empty list; an internal init takes the outcomes.
    - `session/new` and `session/resume` both go through `composeSession` -> `ToolCatalog.sessionSurface(context:)`. Tests read the outcomes through `agent.sessions[id]?.surface.mcpServerOutcomes`.
    - `Refusal.nameCollision` and `Refusal.mcpDisabled` do not carry the transport. Thus the roster records the refusal outcomes when it composes, because there it still has the wire value of each refused server. An unknown transport has no transport: the outcome holds `transport == nil`.
    - `MCPServer.connect(via:)` leaves the server `.faulted` on failure. For a client failure the session continues, so the failed server is disconnected and its subprocess is shut down, to leak nothing.
    - `StdioServerProcessError` has `commandNotAbsolute` and `pipeCreationFailed`. Only `commandNotAbsolute` maps to the "command is not an absolute path" reason; the other maps to the connect failure reason.
  timestamp: 2026-10-07T16:42:14.141709+00:00
- actor: claude-code
  id: 01m4bmm17qjb7dhvk6gack2m41
  text: |-
    Implementation landed (TDD: the new tests first did not compile, because `MCPComposition.ServerOutcome` and `SessionSurface.mcpServerOutcomes` did not exist).

    What changed:
    - `MCPComposition.swift`: new `ServerOutcome` (`Transport` with `wireName` from `stdioTransportName`/`httpTransportName`, `Origin`, `FailureReason` with String raw values as agent texts and `init(connectError:)` that reads only the type and the case of the error, `Result`). `Roster.entries` is now `[Roster.Entry]` (configuration + origin), and `Roster.refusalOutcomes` holds one `.failed` outcome for each refused server that has a name. `Refusal.failureReason` maps each refusal case to its reason. `ConnectedServers.outcomes` = entry outcomes in mount order + refusal outcomes. New `connect(entry:servers:processes:)`: a client failure disconnects the failed server, shuts its subprocess down and gives `.failed`; a config failure also shuts everything down and throws again. The span connect and `connectToReady` now take the server, so the caller can disconnect a server that is `.faulted`. `transportName(of:)` became `transport(of:)` + `wireName`.
    - `ToolCatalog.swift`: `BuiltRegistry.mcpServerOutcomes`; internal `SessionSurface.mcpServerOutcomes` with an internal init; the public init stays and delegates with `[]` (`MCPComposition` is internal, so the member cannot be public).

    Discovery: `TelemetryContentSafetyTests.connectUnreachableServer` also pinned the old throw of `session/new` for an http client server that cannot connect. It now expects a session with `[elicitor .connected (config), remote .failed(.connectFailed) (client)]`. The capture still forbids the URL marker in every record, and the connect span still sees the error.

    An unknown transport has no transport: its outcome holds `transport == nil`.
  timestamp: 2026-10-07T16:54:49.335959+00:00
- actor: claude-code
  id: 01m4bmm4s7p8en0y3y1tv59gnm
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift (+10 tests, roster tests adapted to `Roster.Entry`), Tests/FoundationModelsACPAgentTests/AgentSpanTests.swift (broken-server test now expects a session and a `.failed` outcome), Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift (+1 resume test), Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift (unreachable http server now expects a session). `swift test --scratch-path …/scratchpad/rel-build`: 762 tests in 84 suites passed, 1 known issue (existing `withKnownIssue` in HarnessSmokeTests). Package.resolved not changed. No ARCHITECTURE.md in the repo.
    - next: /review
  timestamp: 2026-10-07T16:54:52.967740+00:00
position_column: doing
position_ordinal: '80'
title: Keep the outcome of each MCP server connect, and start the session when a client MCP server fails
---
## What

The UI must show the MCP servers of a session and the status of each server. The agent must tell the client that it supports MCP servers, it must accept the servers of the client, it must connect to them, and it must keep the result of each connect. A later task (MCP server status report) sends that result to the client.

### What the agent does now

Most of the MCP capability is already in the code. Do not write it again:

- `RoutedACPAgent.advertisedCapabilities` in `Sources/FoundationModelsACPAgent/Agent/Initialization.swift` already sends `capabilities.session.mcp = MCPCapabilities(http: MCPHTTPCapabilities(), stdio: MCPStdioCapabilities())` in the `initialize` response (https://agentclientprotocol.com/protocol/v2/initialization#param-mcp). `InitializationTests.advertisedCapabilitiesCarryTheFourSessionMarkersAsObjects` in `Tests/FoundationModelsACPAgentTests/InitializationTests.swift` already checks `session["mcp"] == {"stdio": {}, "http": {}}`.
- `createSession(_:)` in `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift` and `restoreSession(_:)` in `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` already give `params.mcpServers ?? []` to `composeSession(...)`. `ToolCatalog.makeRegistry(context:)` then calls `MCPComposition.connectServers(section:clientServers:)`.
- `MCPComposition` in `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift` already normalizes `MCPServerHTTP` and `MCPServerStdio` (`normalize(_:)`), applies the collision rule and `mcp: false` (`composeRoster(section:clientServers:)`, type `Refusal`), and connects each entry to `.ready` (`connect(entry:spawnedProcesses:)`, `connectToReady(entry:spawnedProcesses:)`).

### The gap that this task closes

1. `connectServers(section:clientServers:)` throws on the first connect failure. Thus one broken client-supplied server makes all of `session/new` fail, and no session exists to show a "failed" status. `AgentSpanTests.serverThatFailsToConnectRecordsTheErrorTypeOnItsConnectSpan` pins this behavior now.
2. The result of each server is not kept. `ConnectedServers` holds only the connected `FoundationModelsMultitool.MCPServer` values and the `refusals`. `BuiltRegistry` and `SessionSurface` in `Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` hold only `mcpServers` (the connected servers).

### Approach

- In `MCPComposition.swift`, add one value type for the result of one server, for example `MCPComposition.ServerOutcome` with: `name: String`, `transport: Transport` (`.stdio` or `.http`, use the existing `stdioTransportName` and `httpTransportName` for the wire text), `origin: Origin` (`.config` or `.client`), and `result: Result` (`.connected`, or `.failed(reason: FailureReason)`).
- `FailureReason` is a closed enum of agent texts, never the description of the thrown error. The description of the error can hold a URL, an argument, an `env` value or a `headers` value, and these are secrets (see the `Refusal.logMetadata` and the connect span documentation). Use one case for each cause: the command is not an absolute path (`StdioServerProcess.StdioServerProcessError`), the url does not parse (`MCPCompositionError.invalidServerURL`), the connect or the ready wait failed (any other error), the name collides with an earlier server (`Refusal.nameCollision`), MCP is off (`Refusal.mcpDisabled`), and the transport is not known (`Refusal.unknownTransport`, only when the payload has a name).
- Change `connectServers(section:clientServers:)`: a connect failure of a CLIENT-SUPPLIED entry does not throw. Record a `.failed` outcome, keep the connect span error status and `AgentMetrics.recordMCPConnectFailure(transport:)`, shut down the subprocess of that entry, and continue with the next entry. A connect failure of a CONFIG-DERIVED entry still throws and still shuts down all servers, as now. The config is the committed intent of the user, and `SystemToolsProber` (`Sources/FoundationModelsACPAgent/Doctor/ToolsProber.swift`) uses this throw. The roster must know the origin of each entry, so `Roster` must keep the origin next to each `MCPServerConfiguration`.
- Add `outcomes: [ServerOutcome]` to `ConnectedServers`, in mount order, then one `.failed` outcome for each refusal that has a server name.
- In `ToolCatalog.swift`, carry the outcomes through `BuiltRegistry` into a new `SessionSurface` member `mcpServerOutcomes: [MCPComposition.ServerOutcome]`, so `SessionComposition.surface` gives them to the session setup.

## Acceptance Criteria

- [x] The `initialize` response still carries `capabilities.session.mcp` with `stdio` and `http` as empty objects, and the existing test still passes.
- [x] `session/new` with a client-supplied stdio server whose command is not an absolute path returns a session. The surface outcome of that server is `.failed` with the "command is not an absolute path" reason.
- [x] `session/new` with a client-supplied http server whose url does not parse returns a session with a `.failed` outcome for that server.
- [x] A client-supplied server that connects gives a `.connected` outcome, and its tools mount as now.
- [x] A config-derived server that fails to connect still makes `connectServers(section:clientServers:)` throw, and leaks no server and no subprocess.
- [x] Each refusal with a name (`nameCollision`, `mcpDisabled`, `unknownTransport` with a name) gives one `.failed` outcome with its reason. An unknown transport with no name gives no outcome.
- [x] No outcome holds an `env` value, a `headers` value, a URL, a command argument or the description of an error.
- [x] `SessionSurface.mcpServerOutcomes` lists the outcomes in mount order: config servers first, then client servers.
- [x] `session/resume` gives the same outcomes for the `mcpServers` of the resume request.

## Tests

- `Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift`: add tests for the client-supplied connect failure (relative stdio command, url that does not parse) that return outcomes and do not throw; for a config-derived failure that still throws (the existing `aRelativeStdioCommandThrowsInsteadOfSpawning` and `anHTTPServerURLThatDoesNotParseThrows` use config servers and must still pass); for a `.connected` outcome of a loopback server; for the outcome of each refusal; and for an outcome that holds no secret.
- `Tests/FoundationModelsACPAgentTests/AgentSpanTests.swift`: change `serverThatFailsToConnectRecordsTheErrorTypeOnItsConnectSpan` so that `session/new` returns a session, and the connect span still has the error status, the error type and the server name, as a child of the `session/new` span.
- `Tests/FoundationModelsACPAgentTests/InitializationTests.swift`: the existing `advertisedCapabilitiesCarryTheFourSessionMarkersAsObjects` stays green with no change.
- Command: `swift test --filter "MCPCompositionTests|AgentSpanTests|InitializationTests"`, then `swift test` for the full hermetic suite.

## Subtasks

- [x] Add `ServerOutcome`, `Origin` and `FailureReason`, and keep the origin of each entry in `Roster`.
- [x] Change `connectServers(section:clientServers:)` so a client-supplied connect failure gives a `.failed` outcome and does not throw, and a config-derived failure still throws.
- [x] Add a `.failed` outcome for each refusal that has a name.
- [x] Carry the outcomes through `BuiltRegistry` into `SessionSurface.mcpServerOutcomes`.
- [x] Change the broken-server test in `AgentSpanTests.swift` to the new behavior.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.
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
- actor: claude-code
  id: 01m4bmmp2w7m7f9f4qcwfwbmy5
  text: |-
    ### test — green
    - evidence: swift test (scratch rel-build): 762 tests in 84 suites passed, 1 existing known issue.
    - next: commit, review HEAD~1..HEAD
  timestamp: 2026-10-07T16:55:10.684462+00:00
- actor: claude-code
  id: 01m4bn0h5anfbbmjfktm1d673t
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (cdc4982), 5 findings (5 confirmed, 0 refuted) — Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift:177, :198, :202, :205, :208
    - next: implement the 5 open items in the "Review Findings (2026-10-07 11:55)" section, then review again.
  timestamp: 2026-10-07T17:01:38.858201+00:00
- actor: claude-code
  id: 01m4bn105ymz9d752rxe89y8zv
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files
    - test: green — swift 762 passed
    - commit: cdc4982
    - review: findings — MCPComposition.swift:177 (data-driven), :198, :202, :205, :208 (assign-only properties of ServerOutcome)
  timestamp: 2026-10-07T17:01:54.238853+00:00
- actor: claude-code
  id: 01m4bnd2cm223na0ctf3d228bq
  text: |-
    Review findings (2026-10-07 11:55) fixed. Each finding, word for word:
    1. `MCPComposition.swift:177` `code-hygiene/data-driven` — "Error-type-to-case mapping written as an if-else chain. ... Replace the if-else chain with a static mapping." Fix: `FailureReason.connectErrorReasons` is now a static table of rows `(matches, reason)`; `init(connectError:)` reads the first row that matches, else `.connectFailed`. No other if-else chain over a known set stays in the file. The exhaustive `switch` statements over enums stay (the rule carve-out: the compiler checks them).
    2-5. `:198`, `:202`, `:205`, `:208` `code-hygiene/dead-code-swift` — "var.instance `name` / `transport` / `origin` / `result` is assignOnlyProperty." Fix: production code now reads each property. `connectServers(section:clientServers:)` writes one log record for each outcome (new `log(outcomes:)`), with `ServerOutcome.logMetadata` (reads `name`, `transport`, `origin`, `result`) and `Result.logLevel` / `Result.logMessage`. A connected server gives an `info` record, a failed server gives a `warning` record. I did not use `// periphery:ignore`, because a real reader exists now.

    Telemetry no-content rule: the record holds the server name, the transport wire text, the origin raw value (`config`/`client`), the result (`connected`/`failed`) and the case name of the failure reason. It holds no URL, argument, env value, headers value or error description (the outcome holds none). The message does not hold the server name. New `LogMetadataKey` entries in ACPAgentTelemetry: `mcpServerTransport` (= the span attribute key), `mcpServerOrigin`, `mcpServerResult`, `mcpFailureReason`. `TelemetryContentSafetyTests.noTelemetryRecordCarriesTheContentOfTheClient` drives these records under the forbidden markers and passes.

    TDD: new test `MCPCompositionTests.eachOutcomeWritesOneRecordWithItsNameTransportOriginAndResult` (connected stdio, failed relative stdio with secret arg and env, name-collision http with secret url and header, captured with those secrets forbidden). RED: zero outcome records. GREEN after the change.

    Changed existing test: `aRefusedClientServerWritesOneErrorWithItsNameInMetadataAndNoSecret` filtered records only by the server name. The outcome record of the same refused server also has that name, so the filter now also requires the refusal reason key. The assertion (exactly one refusal record) is the same.

    Considered as a better production reader: the `_mcp_server_status` session update (^cbqsngc). That is a separate task, so the log record is the reader in this task's scope.
  timestamp: 2026-10-07T17:08:29.716176+00:00
- actor: claude-code
  id: 01m4bnd4tn1jch8s4mrkyxv2t4
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift, Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift, Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift (+1 test, 1 test filter adapted). `swift test --scratch-path …/scratchpad/rel-build`: 763 tests in 84 suites passed, 1 known issue (existing `withKnownIssue`). No compiler warning. Package.resolved not changed. 5/5 findings checked.
    - next: /review
  timestamp: 2026-10-07T17:08:32.213167+00:00
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

## Review Findings (2026-10-07 11:55)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift:177` `code-hygiene/data-driven` — Error-type-to-case mapping written as an if-else chain. The arms differ only in which error type is checked and which FailureReason case is assigned — this is a lookup table (error type → FailureReason) written as control flow. Replace the if-else chain with a static mapping. For example, create a dictionary or helper function that maps the error type and case to the FailureReason, eliminating the parallel arms.
- [x] `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift:198` `code-hygiene/dead-code-swift` — var.instance `name` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift:202` `code-hygiene/dead-code-swift` — var.instance `transport` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift:205` `code-hygiene/dead-code-swift` — var.instance `origin` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift:208` `code-hygiene/dead-code-swift` — var.instance `result` is assignOnlyProperty.

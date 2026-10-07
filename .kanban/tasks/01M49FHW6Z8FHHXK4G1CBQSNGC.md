---
comments:
- actor: claude-code
  id: 01m4bnzvcjwrs76x22996sb6kj
  text: |-
    Research:
    - `activateSession` in SessionSetup.swift is the one mount point for `session/new` and `session/resume`. `publishAvailableCommands` already schedules work with `afterRespondingToCurrentRequest` and keeps the connection weakly (task ^173qn8n). The report uses `afterRespondingInCurrentServiceContext` and a weak connection the same way.
    - The resume replay is sent in the handler, before the response. Work scheduled after the response comes after the replay.
    - `SessionUpdate.unknown(String, JSONValue)` encodes the discriminator as `sessionUpdate` and the members of the payload object beside it.
    - `ServerOutcome.Transport.wireName` gives `stdio`/`http`, and `ServerOutcome.Origin.rawValue` gives `config`/`client`. The report uses both.
    - `ServerOutcome.transport` is `nil` only for a client server whose transport the agent does not know (reason "The transport is not known."). The card does not say what `transport` holds then. Decision: the update has no `transport` member for that one case. The client task d8d4384 must accept an update with no `transport` (its rule "ignore a member that is not known" does not cover a missing member).
    - Order proof on the wire: `AgentClientHarness.makeRecording(tapsWire:)` and `WireTap.lines`. ScriptedPromptFixture.make(loader:tapsWire:) gives it.
  timestamp: 2026-10-07T17:18:45.138754+00:00
- actor: claude-code
  id: 01m4bpe4jsq6f6xc9k7xd9fb9m
  text: |-
    ### implement — changed
    - evidence: `swift test --filter MCPServerStatusReportTests` 11/11 pass (RED first: a compile failure for the missing type, then 6 end-to-end failures with no report scheduled). Full `swift test` (scratch path rel-build): 774 tests in 85 suites pass, 0 failures. The 1 known issue is the deliberate self-test in HarnessSmokeTests, and it was there before this change. Files: Sources/FoundationModelsACPAgent/Agent/MCPServerStatusReport.swift (new), Agent/SessionSetup.swift (`reportMCPServerStatus(_:of:)`, which `activateSession` calls), Agent/SessionHistory.swift (historySink doc), Tools/MCPComposition.swift (Origin doc: raw value is also the wire text), Tests/FoundationModelsACPAgentTests/MCPServerStatusReportTests.swift (new), Tests/.../Support/ResumeSessionFixture.swift (`mcpServers:` and `tapsWire:` parameters).
    - note: an MCP server name must be a legal identifier for the loopback mount. The first test run used "status-loopback", and the session/new failed. The tests now use camelCase names.
    - note: an update has no `transport` member when the agent does not know the transport (reason "The transport is not known."). The client task d8d4384 must accept this.
    - next: /review
  timestamp: 2026-10-07T17:26:33.305156+00:00
depends_on:
- 01M49FHRMD31QHAZSQG3YWMBW4
position_column: doing
position_ordinal: '80'
title: Report the status of each MCP server of a session as a _mcp_server_status session update
---
## What

The UI must show the status of each MCP server of a session. The agent must send the status of each server to FoundationModelsACPClient. The client task d8d4384 in the FoundationModelsACPClient board ("apply the MCP server status reports of the agent to the MCPServerItem of each server") reads the shape below. The two sides must use the SAME shape. Do not change the shape without a change to the client task.

ACP v2 alpha.7 has no session update for the status of an MCP server. Thus this task defines an extension update kind.

### Why a `session/update` kind and not a separate notification

- Do NOT send a separate JSON-RPC notification (for example `_mcp/server_status`). FoundationModelsACP drops an unknown notification (`RoleConnectionCore.swift:74`, and the `default: break` arm of `ClientSideConnection.serveNotification`), and the `Client` protocol has no extension hook. A separate notification needs an upstream change.
- A `session/update` whose `sessionUpdate` value FoundationModelsACP does not know decodes as `SessionUpdate.unknown(type, payload)` and goes to the client through `SessionUpdateRouter`. No upstream change is necessary.
- This follows the pattern that the repo already uses. Custom wire values start with `_` (`PromptExecution.unmappedStopReasonValue = "_error"`, `EventProjection.lostStatusWireValue = "_lost"`), and ACP says that names that start with `_` are free for custom use. `CompactionReporter.post(_:)` in `Sources/FoundationModelsACPAgent/Agent/CompactionReporter.swift` already sends updates that stable ACP does not know as `SessionUpdate.unknown`.

### The message shape (exact)

Method: `session/update` (a notification, agent to client). The update kind: `"sessionUpdate": "_mcp_server_status"`. One update for each server. The members of `update`:

| Member | Type | Required | Values |
|---|---|---|---|
| `sessionUpdate` | string | yes | `"_mcp_server_status"` |
| `name` | string | yes | The server name. It is the same `name` as in the `mcpServers` entry of `session/new` or `session/resume`, or the name of a config-derived server. It is the key of the server. |
| `transport` | string | yes | `"stdio"` or `"http"` |
| `origin` | string | yes | `"client"` (from the `mcpServers` of the request) or `"config"` (from the `mcp:` section of the agent configuration). The client did not send a config server, so it adds an item for a name that it does not have. |
| `status` | string | yes | `"connecting"`, `"connected"`, `"failed"` or `"closed"` |
| `reason` | string | only when `status` is `"failed"` | A short agent text. It never holds a URL, a command argument, an `env` value, a `headers` value or the description of an error. |

Rules for the receiver: the last update for a `name` replaces the status of that server. Ignore a `status` value that is not known, and ignore a member that is not known. The update is a live status, not a transcript entry: do not give it to `SessionMergeEngine`, because `SessionMergeEngine.applyUnknown` appends an unknown update as a `SessionEntry` of kind `.unknown`.

Example, a connected server:

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "01K9Z3M4Q8T2V6X0B5C7D9E1F3",
    "update": {
      "sessionUpdate": "_mcp_server_status",
      "name": "github",
      "transport": "http",
      "origin": "client",
      "status": "connected"
    }
  }
}
```

Example, a failed server:

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "01K9Z3M4Q8T2V6X0B5C7D9E1F3",
    "update": {
      "sessionUpdate": "_mcp_server_status",
      "name": "files",
      "transport": "stdio",
      "origin": "client",
      "status": "failed",
      "reason": "The command is not an absolute path."
    }
  }
}
```

The `reason` texts come from `MCPComposition.FailureReason` (task "Keep the outcome of each MCP server connect"): the command is not an absolute path; the url does not parse; the server did not connect or did not become ready; the name collides with an earlier server; MCP is off in the configuration; the transport is not known.

### When the agent sends the updates

- The servers connect in `composeSession(...)`, before the session id exists, and the client knows the session id only from the response. Thus the agent sends the report AFTER the response of `session/new` and of `session/resume`: one `_mcp_server_status` update for each entry of `composition.surface.mcpServerOutcomes`, in mount order. `.connected` gives `"connected"`, and `.failed(reason:)` gives `"failed"` with the `reason` text.
- Put the call in `activateSession(_:composition:workingDirectory:additionalRoots:indexRecorded:history:)` in `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift`, because `createSession(_:)` and `restoreSession(_:)` both call it. Schedule the sends with `AgentSideConnection.afterRespondingInCurrentServiceContext(_:)` (`Sources/FoundationModelsACPAgent/Telemetry/RequestTracing.swift`) on the bound connection. A resume sends a full new report, and the client replaces its list.
- Send the updates with `AgentSideConnection.post(_:in:)` directly, NOT through `historySink(for:connection:)`. The status is live and must not go into the retained history or into a replay (as a `notice` is "a live event and not part of the session history"). Change the documentation of `historySink(for:connection:)` in `Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift`, which says that each update goes through a history sink except the replay, so that it names this second exception.
- This task sends `"connected"` and `"failed"` only. `"connecting"` and `"closed"` are in the shape so that the client can show them. A later task can send them from a live watch: `FoundationModelsMultitool.MCPServer` has a public `state` (`MCPServerState`: `.connecting`, `.ready`, `.disconnected`, `.faulted(String)`) but no public stream of state changes now.

### Files

- `Sources/FoundationModelsACPAgent/Agent/MCPServerStatusReport.swift` (new): the wire constant `"_mcp_server_status"`, the `status` and `transport` and `origin` wire texts, and the encode of one `MCPComposition.ServerOutcome` to `SessionUpdate.unknown("_mcp_server_status", payload)`.
- `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift`: the scheduled report in `activateSession(...)`.
- `Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift`: the documentation of `historySink(for:connection:)`.
- `Tests/FoundationModelsACPAgentTests/MCPServerStatusReportTests.swift` (new).

## Acceptance Criteria

- [x] After the `session/new` response, the client gets one `session/update` with `sessionUpdate` `"_mcp_server_status"` for each server of the session, in mount order, with `name`, `transport`, `origin` and `status` as the table above gives.
- [x] A client-supplied server that fails to connect gives `"status": "failed"` and a `reason` from the fixed texts. The `reason` holds no URL, no argument, no `env` value and no `headers` value.
- [x] A refused client-supplied server (name collision, `mcp: false`) gives `"status": "failed"` with its reason.
- [x] No status update arrives before the response of `session/new`.
- [x] After the `session/resume` response, the client gets a full report for the servers of the resume request.
- [x] A session with no MCP server sends no `_mcp_server_status` update.
- [x] The update does not go into the retained history: a resume with replay sends no old `_mcp_server_status` update.
- [x] On the client side, the update decodes as `SessionUpdate.unknown("_mcp_server_status", payload)` with no change to FoundationModelsACP.

## Tests

- `Tests/FoundationModelsACPAgentTests/MCPServerStatusReportTests.swift` (new):
  - The encode of each outcome gives the exact JSON members of the table (compare the encoded `UpdateSessionNotification` with the JSON examples above).
  - Through the in-process harness (`Tests/FoundationModelsACPAgentTestSupport/Harness.swift`, or `ScriptedPromptFixture` with `mcpServers:`): `session/new` with one loopback server and one stdio server with a relative command gives one `"connected"` and one `"failed"` update after the response, and the session works.
  - A session with no server sends no status update.
  - `session/resume` sends a new report, and a replay holds no `_mcp_server_status` update.
  - No `reason` holds a value of the `env`, the `headers` or the URL of the server.
- Command: `swift test --filter MCPServerStatusReportTests`, then `swift test` for the full hermetic suite.

## Subtasks

- [x] Add `MCPServerStatusReport.swift` with the wire constants and the encode of one outcome to `SessionUpdate.unknown`.
- [x] Schedule the report after the response in `activateSession(...)`, sent with `post(_:in:)` and not through the history sink.
- [x] Change the documentation of `historySink(for:connection:)` to name the second exception.
- [x] Add the end-to-end tests for `session/new`, `session/resume`, no server, and no secret in `reason`.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5g2j7hv60pshamcccwy07sj
  text: |-
    Research (picked up). Baseline `swift test`: 1174 tests in 127 suites, 1 known issue.
    - FoundationModelsACP (270f9e3, = origin/main) has NO HTTP transport (ACP-1) and NO `_` extension-method dispatch (ACP-3). So no transport gives an `Acp-Connection-Id` today: every connection (stdio, InMemoryTransport) gets an id from the agent at bind.
    - The wire `Agent` protocol carries no connection context, and `AgentSideConnection` builds one `any Agent` per connection with its factory. Plan (listen and fork): `bind(connection:)` mints a `ConnectionId`, adds a row to a `ConnectionTable` (Mutex, because the factory closure is synchronous) and returns a `RoutedACPConnection: Agent` that forwards each call to the one `RoutedACPAgent` with its id. The row holds the client capabilities of its `initialize`, the trust (`GraphQLViewer.Trust`, `userDevice` until ^ACPA-5b) and a weak ref to its `AgentSideConnection` (the outbound path).
    - `RoutedACPAgent` keeps its own `Agent` conformance as the `direct` caller (tests and in-process calls with no wire): a row with no outbound path.
    - Outbound: each session's `session/update`, elicitation and command list go to the connection of the session (the one that made or resumed it; ^ACPA-5c makes this the owner with the takeover rules). Today every one of them reads the one agent-wide `boundConnection`.
    - Connection close (until ^ACPA-5d): the teardown closes only the sessions of that connection, and the settings watch stops when no wire connection is left.
  timestamp: 2026-10-21T20:31:09.883182+00:00
- actor: claude-code
  id: 01m5g3r00nrmhstztdhqvnet02
  text: |-
    ### implement — changed
    - evidence: 8353a3f. RED first: ConnectionTableTests.eachSessionOfTwoBoundConnectionsUpdatesItsOwnConnection failed (`firstReceiver == 0`: the idle of the first connection's session went out on the second connection, because the second bind replaced the first). Then eachBoundConnectionKeepsTheCapabilitiesOfItsOwnInitialize (new API: RoutedACPConnection.id/clientCapabilities). GREEN: both pass. Full `swift test`: 1176 tests in 128 suites passed, 1 known issue (baseline 1174/127).
    - New: Agent/ConnectionTable.swift (ConnectionId, ConnectionTrust = GraphQLViewer.Trust, ConnectionRow, ClientPath, ConnectionTable), RoutedACPConnection.swift. Changed: RoutedACPAgent, Initialization, SessionSetup, SessionResume, SessionLifecycle, SessionList, PromptExecution, ConfigOptions, SessionHistory, ElicitationRelay, CommandDispatch, ComposedAgent; test support Harness.routedConnection; call sites in 7 existing tests (no assertion weakened).
    - Notes for next cards: the session -> connection map in ConnectionTable (`sessionConnections`) is set at session/new and session/resume; ^3xk7pa4 turns it into the owner with the takeover rules and adds the started-by record. A connection close still closes that connection's own sessions (`tearDownConnection`); ^s415rd3 changes that to "free".
    - next: ^3xk7pa4
  timestamp: 2026-10-21T20:51:47.349439+00:00
position_column: done
position_ordinal: ffff8380
title: 'ACPA-5a: one agent with a connection table; a bind adds a RoutedACPConnection and does not replace the last one'
---
Spec: TestudoApp features/packages/foundationmodels-acpagent.md#acpa-5-one-agent-with-a-connection-table, D120 (TestudoApp 9311882). Status agreed.

## Change
- ONE `RoutedACPAgent` (the listener), and a `RoutedACPConnection` for each connection id, as in listen and fork.
- The key is the connection id: the `Acp-Connection-Id` of ACP v2 from `initialize`. Stdio and InMemoryTransport have no header, so the agent gives them an id at bind. All transports then take one path.
- Each connection row holds the client capabilities of its `initialize`, its trust (set by ^ACPA-5b; `userDevice` until then), and its outbound path for requests and notifications.
- Today `bind(connection:)` replaces the last connection, and `negotiatedClientCapabilities` is agent-wide. Both move into the connection row.
- Shared state stays ONE instance on the agent: the model pool, settingsStore and the settings endpoint, the hooks and the SnapshotStore, the session table and the session directory.

## Done when
- A failing test first (TDD): two connections are bound to one agent at the same time, each with its own client capabilities. A call on each one goes out on its own path, and a second bind does not end the first.
- The full `swift test` passes. #acpa-5
---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
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
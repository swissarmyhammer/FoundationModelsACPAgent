---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5g6nehqmqcyn29g1qehnbt4
  text: |-
    ### implement — stuck
    Blocked upstream. The test needs a `_sah/graphql/settings` call over the wire from each of two connections, and today no connection can make one:
    - FoundationModelsACP (origin/main 270f9e3) has the wire types of the tunnel (ACP-5, `SAH/SAHGraphQL.swift`: `_sah/graphql/execute|subscribe|unsubscribe|endpoints`), but no dispatch for `_` methods (ACP-3). `AgentSideConnection` serves only the generated method table, and its `default:` throws `methodNotFound` (`Connection/AgentSideConnection.swift`, `RoleConnectionCore.swift`). The `Agent` protocol has no extension-method hook.
    - No tunnel host exists: nothing in this package (or in its dependencies) handles `_sah/graphql/*`, and the spec puts the handlers in the server host (testudoapp.md, APP-16, "the GraphQL tunnel (D55)").

    What is needed first:
    1. FoundationModelsACP ACP-3: a host registers handlers for `_` requests and notifications on `AgentSideConnection`, and each handler gets the connection it came on (so the agent can name its `ConnectionId`).
    2. A tunnel host that serves `_sah/graphql/execute` for the `settings` endpoint (`RoutedACPAgent.settingsEndpoint`) on each bound connection.
    Then this test can be written as specified: two connections, sessions in two cwds, the same `cursor` from both, and a change from one shown in `changes(after:)` on the other. The parts that exist now (one agent, two connections, the connection table, owners: ACPA-5a/5c/5d) are done.
    - evidence: no code change; FoundationModelsACP 270f9e3 checked.
    - next: unblock on ACP-3 + the tunnel host.
  timestamp: 2026-10-21T21:42:49.655463+00:00
depends_on:
- 01M5G0JS7YFSWXJXXHEZNEPBKJ
- 01M5G0K65FDK5TE2MG93XK7PA4
position_column: todo
position_ordinal: '8780'
title: 'ACPA-5e: build-time test (D88): one agent serves two connections with sessions in different cwds, and the settings endpoint gives both the same cursor'
---
Spec: ACPA-5 Requirement (D88, D120, EXTRAS-9 rule 1).

## Done when
- An integration test exists. One agent has two connections at the same time, each with a session in a different cwd. Each connection makes a `_sah/graphql/settings` call to `cursor`, and both get the same value. A change from one connection shows in `changes(after:)` on the other.
- When the snapshots endpoint is reachable through the tunnel, also check it.
- The full `swift test` passes. #acpa-5 #blocked #blocked-upstream
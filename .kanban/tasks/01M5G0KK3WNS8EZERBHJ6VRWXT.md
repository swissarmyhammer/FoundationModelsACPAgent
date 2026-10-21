---
assignees:
- claude-code
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
- The full `swift test` passes. #acpa-5
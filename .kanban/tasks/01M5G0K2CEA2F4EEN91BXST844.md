---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5g31n475n9cxt2mdbab1aa0
  text: |-
    BLOCKED on FoundationModelsACP ACP-1 (HTTP server transport). Found 2026-10-21, FoundationModelsACP at 270f9e3 (= origin/main):
    - `Sources/FoundationModelsACP/Transport/` has only DescriptorIO, InMemoryTransport, NDJSONCodec, ReplayTransport, StdioTransport, SubprocessTransport. There is no HTTP transport (server or client), no bearer token, and no `Acp-Connection-Id` anywhere in the package (rg over its Sources). The spec page foundationmodels-acp.md lists this as a gap (ACP-1 agreed, not built), and the FoundationModelsACP board has no ACP-1 card.
    - `ACPTransport` and `AgentSideConnection` expose no per-connection metadata, so the agent cannot learn the credential of a connection from what exists.

    What FoundationModelsACP would need (ACP-1), so that this card can be done here:
    1. An HTTP server transport (a listener) that gives one connection per client: the host gets, for each accepted connection, an `ACPTransport` for `AgentSideConnection(stream:)` plus the connection metadata.
    2. That metadata, readable by the host in the `AgentSideConnection` factory (or at accept, before the factory runs): the connection id (`Acp-Connection-Id`, given at `initialize`, sent by the client on each later request, routed by the listener to its connection) and the credential of the connection (the bearer token of `Authorization: Bearer <token>`), never anything from the JSON-RPC body. For example a `ConnectionInfo { id: String; bearerToken: String? }` on the accepted transport, or an `AgentSideConnection.transportInfo` property.
    3. A transport with no header (stdio, InMemoryTransport) reports no id and no credential, as today.

    What ACPAgent does then (this card): `bind(connection:)` takes the connection id from that metadata (else mints one, as now) and the trust from the credential via the host's list of user-device tokens (`userDevice` for a listed token, `external` for any other), into the `RoutedACPConnection` row; `initialize` never changes it.

    Still in force without ACP-1 (from ^ACPA-5a): every stdio and InMemoryTransport connection is `userDevice` (the in-process UI and the local CLI), and the `ConnectionId.direct` caller is `userDevice`. ^ACPA-5c adds a host-given trust at bind (the seam that ACP-1 will feed), so `external` can be tested before ACP-1 lands. No change was made in FoundationModelsACP.
  timestamp: 2026-10-21T20:39:35.303038+00:00
depends_on:
- 01M5G0JS7YFSWXJXXHEZNEPBKJ
- 01M5G72V9BGAQNTKHBXW9NH4C6
position_column: todo
position_ordinal: '8480'
title: 'ACPA-5b: the trust of a connection comes from its credential, never from the client'
---
Spec: ACPA-5 (D120 b), TestudoApp foundationmodels-acpagent.md.

## Change
- The bearer token of the connection gives its trust. The in-process UI and a token of a device of the user give `userDevice`. Any other token gives `external`.
- What the client says at `initialize` does not change the trust.
- The trust goes in the `RoutedACPConnection` row (^ACPA-5a).

## Find out first
- Where the HTTP transport (FoundationModelsACP, ACP-1) exposes the credential of a connection, and how the host gives the list of user-device tokens. If the transport does not expose it, stop and report what FoundationModelsACP would need. Do not edit that repo.

## Done when
- A failing test first (TDD): a connection with a user-device token is `userDevice`, a connection with another token is `external`, and an `initialize` that claims more does not change it. An in-process (InMemoryTransport) connection is `userDevice`.
- The full `swift test` passes. #acpa-5
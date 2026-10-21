---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5g6nr5smrep2rf2xkabewz8
  text: |-
    ### implement — stuck
    Blocked upstream, the same way as ACPA-5e (^j6vrwxt). The card's test is "two connections on one agent each make a `_sah/graphql/*` call, and each endpoint resolver gets a viewer". No `_sah/graphql/*` call can reach the agent today:
    - FoundationModelsACP (origin/main 270f9e3) has the tunnel wire types (ACP-5) but no `_` method dispatch (ACP-3): `AgentSideConnection` throws `methodNotFound` for every method outside the generated table. The spec lists ACP-3 as a dependency of ACPA-13.
    - No tunnel host serves `_sah/graphql/*` (spec: the server host, APP-16 / D55), so there is no call to build a viewer for.
    - The trust field also waits on ACPA-5b (^bxst844, blocked on ACP-1: no HTTP transport and no bearer token). Stdio and in-memory connections are `userDevice` now.

    The data the viewer needs is in place after ACPA-5a/5c/5d: `ConnectionTable` has the connection id, the trust, `owner(of:)` and `starter(of:)` for each session. FoundationModelsExtras main has `GraphQLViewer.startedSessions` (a9ae13b); this package still pins Extras 6716646, and `swift package update FoundationModelsExtras` was NOT run, because nothing can use the field until the tunnel exists.
    What is needed first: ACP-3 (with the connection of each `_` call available to its handler) and the tunnel host. Then: update Extras, build the viewer from the row (clientId = connection id, trust, ownedSessions, clientOwnedSessions, startedSessions), and write the two-connection test.
    - evidence: no code change; FoundationModelsACP 270f9e3 checked.
    - next: unblock on ACP-3 + the tunnel host (+ ACP-1 for trust over HTTP).
  timestamp: 2026-10-21T21:42:59.513031+00:00
depends_on:
- 01M5G0JS7YFSWXJXXHEZNEPBKJ
- 01M5G0K2CEA2F4EEN91BXST844
- 01M5G0K65FDK5TE2MG93XK7PA4
- 01M5G0KG6B1THJF53W3S415RD3
position_column: todo
position_ordinal: '8280'
title: 'ACPA-13: a GraphQLViewer for each _sah/graphql/* tunnel call, from its connection row'
---
Spec: TestudoApp features/packages/foundationmodels-acpagent.md, ACPA-13 (agreed). ACPA-5 is agreed now (D120). It is cards ACPA-5a to ACPA-5e on this board, and this card waits on them. The Multitool session waits on this card for its sessions endpoint (^j5jb3z2en, with `ownedByViewer`/`hasOwner`).

## Change
Each `_sah/graphql/*` call that the tunnel carries gets a `GraphQLViewer` (FoundationModelsExtras `GraphQL/GraphQLViewer.swift`), built from the connection row of the call (^ACPA-5a):
- `clientId` = the connection id
- `trust` = the trust of the connection (^ACPA-5b)
- `ownedSessions` = the ids of the sessions that this connection owns (^ACPA-5c)
- `clientOwnedSessions` = the ids of the sessions that any connection owns

The viewer carries the sets, and the endpoint asks no port.

The `external` visibility rule also needs the sessions that this connection STARTED (D120 e). GraphQLViewer has no field for them yet. That needs an Extras change (for example `startedSessions: Set<String>`), which the Multitool session takes to Extras. Until it lands, fill the fields that exist.

The host also checks the folder of a `sessionFolder` call (EXTRAS-9 rule 4).

## Done when
- A failing test first (TDD): two connections on one agent each make a `_sah/graphql/*` call. Each endpoint resolver gets a viewer with its own connection id and trust, and with the right owned sets.
- The full `swift test` passes. #acpa-13 #blocked #blocked-upstream
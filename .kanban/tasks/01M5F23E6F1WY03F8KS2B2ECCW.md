---
assignees:
- claude-code
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
- The full `swift test` passes. #acpa-13
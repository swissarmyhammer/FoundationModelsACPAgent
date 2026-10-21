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
- actor: claude-code
  id: 01m5gcxg1w4nxjmmtr6samhpk8
  text: |-
    Picked up again after ACP-3/ACP-1 landed (FoundationModelsACP a78fb48). `swift package update FoundationModelsExtras` run: Extras now 589f27e (has `GraphQLViewer.startedSessions`); Package.resolved is gitignored, so no manifest change.

    Research:
    - `AgentSideConnection` reads `Agent.extensionHandlers` once, when the factory returns. The factory returns a `RoutedACPConnection`, which knows its `ConnectionId`, so its handlers can name the calling connection on each `_sah/graphql/*` call. No change to ACP is needed to get the connection of a call.
    - `ConnectionTable` already holds the trust, owners and starters; the viewer comes from one locked read of it.
    - Endpoints: the agent holds the one `settings` endpoint (`settingsEndpoint`). The `snapshots` endpoint is made per session by `SnapshotsCapability(store:)` (identity session-key maps) inside `runCode`; `SnapshotsGraph(store:sessionKey:sessionId:)` is public and shares one change log per store, so the agent can hold one server-scope `snapshots` endpoint over `hooks.snapshotStore` with the same identity maps, and a call with no session reaches it. The session-folder endpoints (kanban, agents, skills, ...) come from `ActiveSession.surface.tools` (`GraphQLEndpointTool`); a host tool from `registerHostTools` is a top-level tool too, which is the seam for the test probe endpoint.
    - Rule 4 (EXTRAS-9): an `external` viewer sees the sessions it owns (and, by the EXTRAS-5 amendment, the ones it started) and their folders; the host checks the folder of a `sessionFolder` call. The wire `ExecuteRequest/SubscribeRequest` carry `sessionId`, which selects the folder, so the check is: the folder of the named session must be the folder of a session the external viewer can see; otherwise `NOT_FOUND` (does not tell that the session exists).
    - Toolkit `CodedError.responseJSON()` gives the `{"errors":[...]}` body for a coded routing error, so the tunnel reuses it.
  timestamp: 2026-10-21T23:32:04.796173+00:00
- actor: claude-code
  id: 01m5gdkazgavvs8ed8yfd61qgv
  text: |-
    ### implement — changed
    - evidence: commit 5352c01. RED: the new GraphQLTunnelTests had 12 tests, and all 12 failed with methodNotFound / no _meta.sah. GREEN: all 12 pass. Full `swift test`: 1190 tests in 130 suites passed, with 1 known issue (HarnessSmokeTests).
    - what: RoutedACPConnection.extensionHandlers -> RoutedACPAgent.graphQLTunnelHandlers(for:) serves execute/subscribe/unsubscribe/endpoints (Agent/GraphQLTunnel*.swift). Routing by name: first the agent endpoints (settings, plus a new agent-level `snapshots` SnapshotsGraph over hooks.snapshotStore with identity key maps), then the endpoints of the top-level tools of the session (SessionSurface.graphQLEndpoints). A call with no session reaches server-scope session endpoints only. ConnectionTable.viewer(of:) builds the viewer in one locked read: clientId = connection id, trust, owned, clientOwned, started. Folder check (EXTRAS-9 rule 4): an external viewer reaches a sessionFolder endpoint only when the folder of the named session is the folder of a session it owns or started; otherwise, and for an unknown or closed session, NOT_FOUND. Codes: UNKNOWN_ENDPOINT (the message lists the known names) and SESSION_REQUIRED. Subscriptions send next, then complete or error. Unsubscribe and the connection close cancel the subscription. initialize now advertises _meta.sah {version, graphql} with the same list as endpoints. Package.resolved (gitignored) is on Extras 589f27e.
    - notes: trust over HTTP still waits on ACPA-5b (bearer -> trust); stdio and in-memory are userDevice. No ACP-1 connectionInfo is used, because the agent mints the connection ids.
    - next: review
  timestamp: 2026-10-21T23:44:00.496501+00:00
depends_on:
- 01M5G0JS7YFSWXJXXHEZNEPBKJ
- 01M5G0K65FDK5TE2MG93XK7PA4
- 01M5G0KG6B1THJF53W3S415RD3
- 01M5G72P3AM0415Q2TWM7WMTRM
position_column: doing
position_ordinal: '80'
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
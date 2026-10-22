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
- actor: claude-code
  id: 01m5gfx78mgwc7jb518rgfjkxt
  text: |-
    Research (FoundationModelsACP a78fb48 resolved): `ACPTransport.connectionInfo` is a protocol requirement (default nil via extension); `HTTPConnectionTransport` gives `ACPConnectionInfo(id:bearerToken:)`; `AgentSideConnection.connectionInfo` is set from the stream before the factory runs. So `bind(connection:)` can read it in the factory.

    Plan: `RoutedACPAgent.init` and `ComposedAgent.compose` take `userDeviceTokens: Set<String> = []` (host config, no store). `bind(connection:)` drops the host `trust:` parameter of ^ACPA-5c (the credential now feeds it): no credential -> userDevice, listed token -> userDevice, other token -> external; the row id is `connectionInfo.id` when present, else a minted ULID. `RoutedACPConnection.trust` reads the row. Test harness: `makeRecording(bearerToken:)` wraps the agent end in a test transport that reports a connectionInfo, replacing `trust:`; `makeStubAgent(userDeviceTokens:)`.
  timestamp: 2026-10-22T00:24:21.524200+00:00
- actor: claude-code
  id: 01m5ggf8ssbpppak59xgrknfrk
  text: |-
    ### implement — changed
    - evidence: 136414d. RED first: ConnectionTrustTests (other token -> external, row id = Acp-Connection-Id, initialize claim) failed by assertion on the old bind; the user-device-token tests and the tunnel viewer test failed to compile (no userDeviceTokens). GREEN: filtered run 28 tests / 4 suites passed; full `swift test` 1202 tests in 131 suites passed, 1 known issue (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps), no warnings beyond the SwiftPM mlx bundle notice.
    - change: `RoutedACPAgent.bind(connection:)` reads `connection.connectionInfo`: row id = its `Acp-Connection-Id`, else a minted ULID (`ConnectionId.make(for:)`); trust = `ConnectionTrust(credentialOf:userDeviceTokens:)`: no connection header (stdio, in-memory) -> userDevice; token in `userDeviceTokens` -> userDevice; any other token OR an HTTP connection with no token -> external. `initialize` never touches it. Host API: `userDeviceTokens: Set<String> = []` on `RoutedACPAgent.init` and `ComposedAgent.compose` (stored as `RoutedACPAgent.userDeviceTokens`; no store). The ACPA-5c `trust:` parameter of `bind` is removed (the credential feeds the row now); `ConnectionTable.add` takes the id.
    - tests: `Tests/FoundationModelsACPAgentTestSupport/CredentialTransport.swift` (wraps a wire end, reports an `ACPConnectionInfo`; `TestBearerToken`; `ACPConnectionInfo.makeHTTP(bearerToken:)`), harness `makeRecording(connectionInfo:)` replaces `trust:`, `makeStubAgent`/`composeStubAgent(userDeviceTokens:)`; `ConnectionTrustTests` (7 tests incl. compose path and HTTP-no-token); `GraphQLTunnelTests.theViewerOfATunnelCallCarriesTheTrustOfItsCredential`; SessionOwnerTests and TunnelFixture now make `external` with an unlisted token.
    - decision to note: an HTTP connection with no bearer token is `external` (not in the card text; it would otherwise be a remote userDevice). No change in FoundationModelsACP.
    - next: /review
  timestamp: 2026-10-22T00:34:12.921625+00:00
- actor: claude-code
  id: 01m5ggrknt42nt9p80jx9sak66
  text: |-
    ### test — green
    - evidence: swift test (root, all Sources/Tests .swift touched to force rebuild of this package): 1202 tests in 131 suites passed, 1 known issue (HarnessSmokeTests orderedSubsequenceAssertionChecksOrderWithGaps), 0 compiler warnings from this package (only SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx.bundle, third-party). python3 -m unittest discover -s bench: 265 tests OK (skipped=1, the swebench skip). IntegrationTests swift test: first run did not build (cannot find ACPConnectionInfo / ExtensionHandlers) because IntegrationTests/Package.resolved pinned stale FoundationModelsACP 270f9e3 (root pins a78fb48); ran `swift package update` inside IntegrationTests only (Package.resolved is gitignored), then swift test: 27 tests in 13 suites passed (incl. ClientInteropTests), 0 failures, 0 skips, 0 compiler warnings.
    - no source change, nothing committed, nothing pushed; no release build; no root swift package update/edit.
  timestamp: 2026-10-22T00:39:18.970957+00:00
- actor: claude-code
  id: 01m5gh22w86ja39gtqjfagx76a
  text: |-
    ### review — findings
    - evidence: review sha f5e02e5..HEAD — 1 finding (1 confirmed, 2 refuted; 7 attempted, 0 failed): Tests/FoundationModelsACPAgentTests/ConnectionTrustTests.swift:99 `swift/initialization`. Recorded in the dated `## Review Findings (2026-10-21 19:39)` section.
    - fact for the implementer: the finding says an array literal does not convert to `Set<String>`. The test record (1202 tests passed, ConnectionTrustTests included) shows this file compiled as written, and `Set` conforms to `ExpressibleByArrayLiteral`. Resolve the finding; if the rule's claim and the compiler disagree, raise it as a conflict for a person to decide.
    - next: /implement the finding, then /review
  timestamp: 2026-10-22T00:44:29.448088+00:00
- actor: claude-code
  id: 01m5gh2n02q13ykjnmthzmre0z
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 136414d (trust from the bearer token, userDeviceTokens, the ACP connection id as the row id)
    - test: green — swift test 1202/131, 1 known issue, 0 package warnings; bench 265 OK; IntegrationTests 27/13
    - commit: dd78e2d
    - review: findings — Tests/FoundationModelsACPAgentTests/ConnectionTrustTests.swift:99 (swift/initialization)
  timestamp: 2026-10-22T00:44:48.002015+00:00
depends_on:
- 01M5G0JS7YFSWXJXXHEZNEPBKJ
- 01M5G72V9BGAQNTKHBXW9NH4C6
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-10-21 19:39)

> Scope: `review sha f5e02e5..HEAD` — reviewed the diffs only — lines this change added or modified. 15 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/ConnectionTrustTests.swift:99` `swift/initialization` — Array literal `[TestBearerToken.userDevice]` passed where `Set<String>` is expected. Swift does not implicitly convert array literals to sets; the argument type does not match the parameter type `Set<String>`. Change to `userDeviceTokens: Set([TestBearerToken.userDevice])`.

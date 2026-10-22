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
- actor: claude-code
  id: 01m5gfgp9q1jrshppm4wscpsrv
  text: |-
    Unblocked: ACPA-13 (5352c01, db9b39b, 6099115) hosts `_sah/graphql/*`. Research:
    - `RoutedACPAgent.tunnelEndpoint(named:)` returns `agentGraphQLEndpoints` (`[settingsEndpoint, snapshotsEndpoint]`, one instance each, made in `RoutedACPAgent.init`) before it looks at the session, so every connection reaches the same `SettingsGraph`/`SnapshotsGraph` objects.
    - `SettingsGraph` ignores the viewer; through the tunnel it runs with no session folder, so a call must name `cwd` itself. `changes(after:cwd:)` with a `cwd` gives the changes of every level (all folders); with no `cwd`, USER only. So the cross-folder check subscribes with the external connection's own cwd and mutates SESSION level of the device connection's cwd.
    - The cursor is `<store epoch UUID>:<seq>`: a second store gives a different epoch, so a per-connection store shows up as two cursors.
    - Tests drive two connections with `TunnelFixture` in GraphQLTunnelTests.swift (userDevice + external, one session each in its own `makeResolvedDirectory`). I extended it with `deviceFolder`/`externalFolder` and gave the `execute`/`subscribe` helpers a `variables` (and `query` for subscribe) parameter.
  timestamp: 2026-10-22T00:17:30.935704+00:00
- actor: claude-code
  id: 01m5gfgww9t9fnp9j2a95w02hy
  text: |-
    TDD record. Three new tests in Tests/FoundationModelsACPAgentTests/GraphQLTunnelTests.swift (MARK "One agent, two connections, two folders (D88, D120)"):
    - `twoConnectionsInTwoFoldersReadOneSettingsCursor`: both connections call `settings` `cursor(cwd:)` for their own session folder over `_sah/graphql/execute`; folders differ, cursors are equal.
    - `aSettingsChangeFromOneConnectionReachesTheChangesOfTheOther`: external subscribes `changes(after: <its cursor>, cwd: <its folder>)` via `_sah/graphql/subscribe`; device runs `updateSetting` SESSION on `compaction.trigger` in its own folder; the external connection gets a `_sah/graphql/next` whose change has that key path and `cwd` = the device folder, a cursor after its own, and no end of the subscription.
    - `twoConnectionsInTwoFoldersReadOneSnapshotsCursor`: both connections call `snapshots` `{ cursor }` with their own session; equal cursors.
    They passed at once (3/3): the shared instance already holds, no bug (no two cursors). To show they can fail I broke the assumption on purpose in `tunnelEndpoint(named:)`: a new `SettingsGraph` over a new `SettingsStore` and a new `SnapshotsGraph` over a new `SnapshotStore` per call. Result: 3/3 failed — settings cursors `013526AF-…:0` vs `C075ECCB-…:0`, snapshots cursors `97C7465D-…:0` vs `7FA78EE5-…:0`, and the change test hit its 1 minute time limit (the change never reached the other connection). Reverted the break with `git checkout` of GraphQLTunnel.swift; no source change ships.
    Full `swift test`: 1194 tests in 130 suites passed, 1 known issue (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps), exit 0.
  timestamp: 2026-10-22T00:17:37.673610+00:00
- actor: claude-code
  id: 01m5gfhfs5jtb2gma20ha6wxee
  text: |-
    ### implement — changed
    - evidence: 63fec16 (Tests/FoundationModelsACPAgentTests/GraphQLTunnelTests.swift only; no source change). New tests 3/3 pass; with a per-connection endpoint/store break in `tunnelEndpoint(named:)` 3/3 fail (two settings cursors, two snapshots cursors, change test times out), break reverted. Full `swift test`: 1194 tests in 130 suites passed, 1 known issue.
    - next: /review. Card left in doing.
  timestamp: 2026-10-22T00:17:57.029763+00:00
- actor: claude-code
  id: 01m5gfmhgxp5m61ce54ynse1f9
  text: |-
    ### test — green
    - evidence: touched all Sources/Tests swift files and Package.swift to force a rebuild of this package, then `swift test` at HEAD 25e6ea7: Build complete, 1194 tests in 130 suites passed, 1 known issue, 0 failures, 0 skipped. `python3 -m unittest discover -s bench`: Ran 265 tests, OK (skipped=1, the old swebench skip). Warnings: 0 from this package sources; the only build line is SwiftPM's own `missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS` (dependency bundle, no file or line in this package).
    - next: none, no code change, nothing to commit
  timestamp: 2026-10-22T00:19:37.117312+00:00
depends_on:
- 01M5G0JS7YFSWXJXXHEZNEPBKJ
- 01M5G0K65FDK5TE2MG93XK7PA4
- 01M5G72P3AM0415Q2TWM7WMTRM
position_column: doing
position_ordinal: '80'
title: 'ACPA-5e: build-time test (D88): one agent serves two connections with sessions in different cwds, and the settings endpoint gives both the same cursor'
---
Spec: ACPA-5 Requirement (D88, D120, EXTRAS-9 rule 1).

## Done when
- An integration test exists. One agent has two connections at the same time, each with a session in a different cwd. Each connection makes a `_sah/graphql/settings` call to `cursor`, and both get the same value. A change from one connection shows in `changes(after:)` on the other.
- When the snapshots endpoint is reachable through the tunnel, also check it.
- The full `swift test` passes. #acpa-5
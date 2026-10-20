---
comments:
- actor: claude-code
  id: 01m5dd2vxg2w93qtfh60nad52m
  text: |-
    Research and work:
    - `swift package update` of agents, hooks, multitool, extras, router and skills in the root package and in `IntegrationTests/`. Both `Package.resolved` files now pin Agents eea0d2b, Hooks c66f336, Multitool d618aa8, Extras 018f9ab (03ceab8 is an ancestor), Router 4b6bcc9, Skills 8e9a828 (no change). The update also adds Graphiti 3.1.0 and GraphQL 4.3.0 (from Extras).
    - `Package.resolved` is in `.gitignore` (both files), thus the pins are local and git shows no change for them.
    - Sources: no use of `agentFolders`, no call of `take`, `checkpoints` or `rollback`, and no exhaustive `switch` on `SnapshotError` (the telemetry gives the case name with `caseName(of:)`, which is generic). Thus the sources need no change.
    - Tests: one call of `checkpoints(sessionKey:)` in HookCompositionTests.swift. It now passes the session id as the owner.

    ### implement — changed
    - evidence: Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift (1 line); `swift test`: 1070 tests in 118 suites passed, 0 failures, 0 warnings (1 known issue of the harness self-test, as before); `swift build --build-tests --package-path IntegrationTests`: Build complete, 0 warnings.
    - next: review
  timestamp: 2026-10-20T19:37:17.488424+00:00
- actor: claude-code
  id: 01m5dd536656kj64vfar3d64z2
  text: |-
    ### test — green
    - evidence: swift test — 1070 tests in 118 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue, accepted), 0 failures, 0 skipped. swift build --build-tests --package-path IntegrationTests — Build complete. Only warning in both runs: SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx bundle (accepted).
    - next: review/commit. No source change was needed. Nothing committed or pushed.
  timestamp: 2026-10-20T19:38:30.470725+00:00
position_column: doing
position_ordinal: '8280'
title: Update the family dependencies to AG-10, HOOKS-5, MT-14 and the GraphQL toolkit
---
## What
The peer sessions pushed changes that the next cards need:
- FoundationModelsAgents main eea0d2b (AG-10): `AgentRegistry` has no `agentFolders`.
- FoundationModelsHooks main c66f336 (HOOKS-5): `take`, `checkpoints` and `rollback` take `owner:`; the old calls are gone. New `SnapshotError.notAvailable(cause: SnapshotUnavailableCause)` and `.noTimeline`; new `timelineSummary(sessionKey:)`.
- FoundationModelsMultitool main d618aa8 (MT-14 and MT-9 `withOperationTool(noun:tool:)`).
- FoundationModelsExtras main 03ceab8 or later (the GraphQL toolkit). Router and Skills: the revisions that the packages above need.

Do this:
- `swift package update` for the family packages in the root package and in `IntegrationTests/`.
- Make ACPAgent compile and pass with the new APIs, with the smallest change. Each call of `take`, `checkpoints` or `rollback` passes the session id as the owner. Each exhaustive `switch` on `SnapshotError` handles the new cases. Remove each use of `agentFolders`.
- Do NOT do the work of ^05sszw4, ^j4pd8zw or ^5ynrv0z here: no new features, only what the build and the current tests need.

## Acceptance Criteria
- [ ] `Package.resolved` pins the revisions above or later.
- [ ] The behavior of ACPAgent does not change.

## Tests
- [ ] `swift test` passes with zero failures and zero warnings.
- [ ] `swift build --build-tests --package-path IntegrationTests` passes.

## Workflow
- No new tests are needed if the behavior does not change; fix the existing tests that use the changed APIs. #acpa-16
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7va7d6ryfqrpg43c6q27xfa
  text: |-
    Research: the importer already gave a source with no root in `unreadableSources` and threw `SessionImportError.sourceUnreadable` for it. `AgentSessionImporterTests` had tests for both at the importer level, and `SessionImportWiringTests` had the `list imports` test with no roots. The new tests prove both again through a composed agent with no root.

    Implementation: `AgentSessionImporter.replaceRoots(_:)` replaces the roots and removes the kept scans of each source agent whose root changed or is gone. `RoutedACPAgent.setImportRoots(_:)` (nonisolated, async) calls it on the one importer. `ComposedAgent.setImportRoots(_:)` calls the agent. An in-flight call is safe: the actor reads the roots only after its last await.

    TDD: the first build failed (no `setImportRoots`). Then `replaceRoots` with no cache drop: the parameterized test "a root that changes and comes back is read again" failed for `moved` and `removed` (the stale title came back). With the drop, it passed. A test proves that an unchanged root keeps its scans.

    Not done here: the last item (push to origin/main and send the sha to testudoapp-9a). The coordinator commits, so the push and the message come after the commit.
  timestamp: 2026-11-20T01:48:06.232491+00:00
- actor: claude-code
  id: 01m7va7g5gm6c0rxr7eppmy1wv
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Sources/FoundationModelsACPAgent/ComposedAgent.swift, Tests/FoundationModelsACPAgentTests/AgentSessionImporterTests.swift, Tests/FoundationModelsACPAgentTests/SessionImportWiringTests.swift, README.md, ARCHITECTURE.md
    - next: test, review, then the coordinator commits, pushes and sends the sha to testudoapp-9a

    ### test — green
    - evidence: `swift build --build-tests` printed "Build complete!" with 0 project warnings; `timeout 1800 swift test --skip-build` gave 2729 tests in 286 suites passed, 0 failures, 1 known issue (the deliberate withKnownIssue in HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps)
    - next: review
  timestamp: 2026-11-20T01:48:09.264914+00:00
position_column: doing
position_ordinal: '8180'
title: 'D209: setImportRoots on the running agent, so a sandbox grant after launch applies with no restart'
---
TestudoApp asked for this on 2026-11-19. In the sandboxed app, the user grants access to `~/.claude` or `~/.codex` through the open panel after launch. The app cannot restart the agent part safely. `ComposedAgent.compose(importRoots:)` and `RoutedACPAgent.init(importRoots:)` set the roots only one time.

## Change
- [x] Add a public `setImportRoots(_ roots: [ImportSourceAgent: URL])` on `RoutedACPAgent` and on `ComposedAgent`. The call replaces all the roots.
- [x] `AgentSessionImporter` reads the new roots at the next `importable` or `importSession` call. Drop the cached file metadata of a root that changed or that is gone.
- [x] An agent with no root: `importable` (the `list imports` action) gives that source in `unreadableSources`, not an empty list. `importSession` throws `SessionImportError.sourceUnreadable` (the endpoint code NO_SOURCE_ACCESS). Prove both with tests. This can be there already; then add only the tests that prove it.
- [x] Tests: no root at launch, then `setImportRoots` with a root, then `importable` lists the sessions of that root, through the real agent and through `ComposedAgent`.
- [x] Update the import sections of `README.md` and `ARCHITECTURE.md`.
- [ ] Push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d209 #import
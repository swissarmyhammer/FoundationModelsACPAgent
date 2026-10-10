---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4kvey2th293zkjaapj264bw
  text: |-
    Picked up. Pin move done with the approved method (swift package update is broken in Swift 6.4 for this graph). I removed only the foundationmodelsacpclient entry from the git-ignored IntegrationTests/Package.resolved and ran `swift package --package-path IntegrationTests --scratch-path IntegrationTests/.build/alt-pin resolve` with a new, empty scratch path. Result: 76 pins before and after; one move only: foundationmodelsacpclient d1cf72d06ca07a827808172a87d2941242f650f9 -> 24643be3817912251e93705443012013b6b6e177. foundationmodelsacp was already at 2268ced292c0daf9ff506a4a9d7609eaf1b052f2, so it did not move. All 76 pins now agree with the root Package.resolved.

    Research:
    - The client 24643be keeps ConnectionModel.connect(over:), ClientSideConnection, ACPClient.supportedProtocolVersion / advertisedCapabilities and AgentProcess. Examples/acp-print uses only these, so it must still build.
    - The root library gives ComposedAgent.compose(name:workingDirectory:environment:modelSource:) and serve(over:) and waitForConnectionTeardown(). RunPrompt (acp-agent run) uses the same drive over InMemoryTransport.pair().
    - Old ClientInteropTests checks: (1) exit 0, (2) answer not empty, (3) no wire frame on client stdout, (4) answer equals the `acp-agent run` answer, (5) ProcessCensus: no `acp-agent acp` process outlives the run.
    - Plan: (1) -> stop reason end_turn; (2) and (4) stay; (5) -> the in-process form is that composed.waitForConnectionTeardown() returns after the wire closes. (3) has no meaning without the binary: the library gives typed session updates and has no stdout. The census also has no meaning: the in-process drive spawns no `acp-agent acp` process, and the yardstick runs `acp-agent run`, which the census does not match.
  timestamp: 2026-10-10T21:28:17.754034+00:00
- actor: claude-code
  id: 01m4kw0h4ccgy58q7ya8kb26mh
  text: |-
    Implementation landed (not committed).

    - RED: with the pin at client 24643be and the old manifest, `swift build --package-path IntegrationTests --scratch-path IntegrationTests/.build/alt --force-resolved-versions --build-tests` failed: "product 'acp-client' required by package 'integrationtests' target 'FoundationModelsACPAgentIntegrationTests' not found in package 'FoundationModelsACPClient'".
    - GREEN: ClientInteropTests now composes `ComposedAgent.compose(... modelSource: .stub)`, serves it over `InMemoryTransport.pair()`, and drives it with `ConnectionModel.connect(over:)` + `ClientSideConnection` (initialize, session/new, subscribe, prompt). Checks: stop reason end_turn, answer not empty, answer equal to the trimmed `acp-agent run` answer. The teardown (`waitForConnectionTeardown()`) is awaited inside the 3-minute limit. Run of the one test: passed in 2.3 s.
    - Removed checks, with the reason in the suite header comment: (a) "no wire frame on client stdout": the library writes no stdout, it gives typed updates; StdioContractTests holds the agent stdout. (b) ProcessCensus "no acp-agent acp outlives the run": the in-process drive spawns no agent process; the yardstick is `acp-agent run`, which the census pattern does not match.
    - IntegrationTests/Package.swift: `clientExecutableName` and the `acp-client` product dependency removed; the client doc comment says the client is a library only.
    - cli-plan.md has no §17 (sections end at §12). I changed every acp-client statement: §2, §5.1, §5.2, §5.8, §5.9, §6 (rewritten as "The client library"), §8, §9, §10 (C11 withdrawn), §12 (new row), and the sibling-plan list at the top (the client cli-plan is gone; the doctor-plan reference now points at §5.12, not §6).
    - Examples/acp-print: no source change needed. `AgentProcess`, `ConnectionModel`, `ACPClient` still exist in 24643be. Build with `--product acp-print` passes.
    - The build prints one llbuild warning in every run: "missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS". It comes from the mlx-swift resource bundle, it was there before this change, and it is not in this code.
    - New task added for a stale fact found in cli-plan §9: the Gate column names ACP_TIER3=1 / ACP_TIER4=1, but no suite has an environment gate (01M4KW05JF6PA1GRF7YDW1B5D9).
  timestamp: 2026-10-10T21:37:54.316381+00:00
- actor: claude-code
  id: 01m4kw0kzxbyqd9fw7jrseda57
  text: |-
    ### implement — changed
    - evidence: 3 files — IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ClientInteropTests.swift, cli-plan.md (plus the git-ignored IntegrationTests/Package.resolved: one pin move, foundationmodelsacpclient d1cf72d -> 24643be; 76 pins, all equal to the root). `swift test --package-path IntegrationTests --scratch-path IntegrationTests/.build/alt --force-resolved-versions --no-parallel`: 30 tests in 11 suites passed. `swift test --scratch-path .build/alt --force-resolved-versions` with an empty SKILLS_MARKETPLACE_CACHE: 883 tests in 96 suites passed (1 known issue that existed before). `swift build --product acp-print`: Build complete.
    - next: /review
  timestamp: 2026-10-10T21:37:57.245163+00:00
- actor: claude-code
  id: 01m4kwb07xqsabcpf9ge7x1ewx
  text: |-
    ### test — green
    - evidence: `swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions` — 30 tests in 11 suites passed, 0 failed. `swift test --scratch-path .build/alt --force-resolved-versions` with SKILLS_MARKETPLACE_CACHE set to an empty scratch folder — 883 tests in 96 suites passed, 1 known issue (the intended withKnownIssue in HarnessSmokeTests), 0 failed. `swift build --product acp-print --scratch-path .build/alt --force-resolved-versions` — Build complete. The only warning in all three runs is the mlx-swift_Cmlx.bundle "missing creator for mutated node" warning from the mlx-swift dependency (expected). No package file warnings. No code was changed.
    - next: none
  timestamp: 2026-10-10T21:43:37.469566+00:00
- actor: claude-code
  id: 01m4kwbq504mqdqfe2z8g1bqfg
  text: |-
    ### commit — changed
    - evidence: 19f2e48 test(integration): drive the agent with the client library in process, and remove the acp-client binary (^dn561z8); kanban commit a2ab247
    - next: none
  timestamp: 2026-10-10T21:44:00.928887+00:00
- actor: claude-code
  id: 01m4kwse3wz0ys79f6rk8pvfwg
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (19f2e48): 0 findings, 0 confirmed, 4 refuted, 7 attempted, 0 failed, 0 skipped. Reviewed: IntegrationTests/Package.swift, ClientInteropTests.swift. Not reviewed: cli-plan.md (no validator matches), 2 .kanban files (.reviewignore). No validator failed because of the orphan checkout in .build. All acceptance items are [x]. Item 1 names the test ClientInteropTests.theClientLibraryGetsTheAgentAnswerOverAnInMemoryTransport, and it exists. Items 2, 3, 4 and the two Tests items name commands or a document change, not a test function.
    - next: none. The task is in done.
  timestamp: 2026-10-10T21:51:30.428970+00:00
- actor: claude-code
  id: 01m4kwt08tp8321phww01z2tbq
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files; IntegrationTests client pin d1cf72d -> 24643be (user-approved resolve method)
    - test: green — IntegrationTests 30; swift test 883 (1 known issue); acp-print builds
    - commit: 19f2e48
    - review: clean — 0 findings; every validator finished; 6/6 acceptance items checked (items 2 to 6 are proved by commands or document changes, item 1 by a named test)
  timestamp: 2026-10-10T21:51:49.018899+00:00
position_column: done
position_ordinal: ffb980
title: 'IntegrationTests: replace the spawned acp-client binary with the FoundationModelsACPClient library over an in-memory transport'
---
## Problem

FoundationModelsACPClient 24643be (pushed 2026-10-10) is a library only. Its user decided this. The `AcpClientCore` library and the `acp-client` executable products are removed, and so are the client's own IntegrationTests package and its `cli-plan.md`. The client no longer exposes StopReason exit codes.

In this repo:
- `IntegrationTests/Package.swift` declares `clientExecutableName = "acp-client"`, and `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ClientInteropTests.swift` builds and runs that binary. The binary does not exist any more, so the suite fails when the IntegrationTests pins move to the client 24643be.
- `cli-plan.md` §6 and §17 describe `acp-client`, and the client side of the exit-code table in §9 is gone.

## Decision (the client's user, 2026-10-10)

Tests run in process, with no spawned client.

## Change

- [x] 1. Move each check of `ClientInteropTests` to the FoundationModelsACPClient library over an in-memory transport (for example `InMemoryTransport.pair()` and the public `ComposedAgent` of ^h72a557). Remove a check that has no meaning without the binary, and record why. Test: `ClientInteropTests.theClientLibraryGetsTheAgentAnswerOverAnInMemoryTransport` (stop reason `end_turn` in place of exit 0; answer not empty; answer equal to the `acp-agent run` answer; `ComposedAgent.waitForConnectionTeardown()` inside the time limit in place of the process census). Removed with the reason in the suite header comment: "no wire frame on stdout" (the library writes no stdout) and the `acp-agent acp` process census (the in-process drive spawns no agent process).
- [x] 2. Remove `clientExecutableName` and the `acp-client` product dependency from `IntegrationTests/Package.swift`. Test: `swift test --package-path IntegrationTests --no-parallel` resolves and builds against client 24643be (before the change the build failed: "product 'acp-client' required by package 'integrationtests' ... not found in package 'FoundationModelsACPClient'").
- [x] 3. Update `cli-plan.md` §6, §9 and §17: remove the `acp-client` binary and the client side of the exit-code table. State that a client is the library. Note: `cli-plan.md` has no §17 (its sections end at §12). Every `acp-client` statement is changed: §2, §5.1, §5.2, §5.8 (the exit-code table is the table of `acp-agent` only; the client library has no exit codes), §5.9, §6 (now "The client library"), §8, §9 (the tier-3 row), §10 (C11 withdrawn), §12 (a new row).
- [x] 4. Check `Examples/acp-print`: it links the client library only. It must still build. Test: `swift build --scratch-path .build/alt --force-resolved-versions --product acp-print` with the client at 24643be: Build complete.

## Tests

- [x] `swift test --package-path IntegrationTests --no-parallel` passes with the client pin at 24643be or later. Result: 30 tests in 11 suites passed.
- [x] The root suite passes. Result: 883 tests in 96 suites passed (1 known issue, the `withKnownIssue` of `HarnessSmokeTests` that existed before).

#tests
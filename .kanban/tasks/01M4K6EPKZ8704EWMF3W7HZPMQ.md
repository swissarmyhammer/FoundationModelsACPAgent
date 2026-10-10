---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4kbs3j174xnzx88rgxxtp3t
  text: 'Research done. All run updates go through `EventProjection.runCallUpdate`. The progress, the attachment report, the settlement and the display content replace send `title: .value(op)`. The SDK `toolCall` (`projectToolCall`) sends `title: .value(name)`, and it comes after the run events of the call. Plan: the projection keeps the set of wire call ids that have a title. A metadata title is always sent and puts its id in the set. The op title (run updates) and the tool name title (SDK `toolCall`) go only on the first titled update of the id, so a later update omits `title`. A content chunk sends no title, so it does not put its id in the set.'
  timestamp: 2026-10-10T16:54:13.825544+00:00
- actor: claude-code
  id: 01m4kca9jzkv2t6bw901p1sprn
  text: |-
    Implementation done. `EventProjection` keeps `titledToolCallIds`, the wire ids that have a title on the client. The new helper `titlePatch(for:defaultTitle:toolTitle:)` gives the title patch of each update. A metadata title always goes on the wire. The `op` of a run (progress, attachment report, settlement, content replace) and the tool name of the SDK `toolCall` go only on the first titled update of the id, and each later update omits `title`. `runCallUpdate` now takes `op:` and an optional `toolTitle:` in place of a `title:` patch. The callers became `mutating`. A metadata event with no title is now the creation with the `op` title when the call has no title yet. A content chunk sends no title and does not record the id.

    TDD: the new tests `aMetadataTitleStaysAfterTheProgressTheReportAndTheSettlement` (ToolDisplayProjectionTests) and `theSdkCallDoesNotWriteItsNameOverAMetadataTitle` (ToolCallJoinProjectionTests) failed before the change and pass after it. `aRunWithNoMetadataTitleShowsItsOp` passed before and after, so it guards the second acceptance case. Each test reads the wire JSON through the new shared reader `[SessionUpdate].lastWireTitle(ofToolCall:)` in ProjectionTestSupport.swift. All the tests use the shared `SyntheticPrompt` driver.

    The full suite found one test that held the old behavior: `TranscriptFidelityTests.theRunCodeCallReachesTheWire` expected the SDK `toolCall` update to send the tool name as its title. The run updates of that call come first, so now the `op` is the one title. The test now checks that the call has exactly one title, and that the first update of the call sends it.

    Discovery: the SDK `toolCall` and `toolStatus` updates come after an inline settlement. They can write `in_progress` and then `completed` over a `failed` or `cancelled` settlement status. New task ^531r4r0 records this.
  timestamp: 2026-10-10T17:03:37.055673+00:00
- actor: claude-code
  id: 01m4kcadc6b7vc1a6wq1qsbn9h
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift, Tests/FoundationModelsACPAgentTests/ToolDisplayProjectionTests.swift, Tests/FoundationModelsACPAgentTests/ToolCallJoinProjectionTests.swift, Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift. Root suite (`swift test --scratch-path .build/alt --force-resolved-versions`, SKILLS_MARKETPLACE_CACHE empty): 874 tests in 94 suites pass, 1 known issue (the `withKnownIssue` test of HarnessSmokeTests that was there before). IntegrationTests (`--no-parallel`, scratch path IntegrationTests/.build/alt): 30 tests in 11 suites pass. No compiler warning. The only warning is the build-system note "missing creator for mutated node" for the mlx-swift_Cmlx bundle, which was also there before the change.
    - next: /review
  timestamp: 2026-10-10T17:03:40.934941+00:00
- actor: claude-code
  id: 01m4kcbs5w1mf62sp8546sayd4
  text: |-
    ### implement — changed
    - evidence: card description only, no code change. The 3 acceptance items are marked `- [x]`, and each item names the test that proves it (file and test name). Each item has a proof, so no item stays open. The test results are as in the earlier record: root 874 tests pass (1 known issue from before), IntegrationTests 30 tests pass.
    - next: /test
  timestamp: 2026-10-10T17:04:25.788650+00:00
- actor: claude-code
  id: 01m4kcnsndk37cezkst1r6fhx4
  text: |-
    ### test — green
    - evidence: `swift test --scratch-path .build/alt --force-resolved-versions` (SKILLS_MARKETPLACE_CACHE set to an empty scratch folder) — 874 tests in 94 suites passed, 0 failed, 0 skipped, 1 known issue (the intentional withKnownIssue in HarnessSmokeTests). `swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions` — 30 tests in 11 suites passed, 0 failed, 0 skipped. The only warning in both runs is the mlx-swift build warning "missing creator for mutated node" for mlx-swift_Cmlx.bundle (dependency, expected). No package file has a warning.
    - next: none. No code changed. Nothing was committed.
  timestamp: 2026-10-10T17:09:53.965948+00:00
- actor: claude-code
  id: 01m4kcpbtrkejf3fh8dd1ke5gt
  text: |-
    ### commit — changed
    - evidence: 506c7c1 fix(acp): keep the title that a tool gives its call, and send an op title only on the first update (^w7hzpmq)
    - next: none. The commit before it is 222a5cf chore(kanban): add task ^531r4r0.
  timestamp: 2026-10-10T17:10:12.568078+00:00
- actor: claude-code
  id: 01m4kcz3wszw6kfz5csmsr30pd
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (506c7c1). Counts: 0 findings, 0 confirmed, 0 refuted. 7 files attempted, 0 failed, 0 skipped. The 2 .kanban files are out of scope because of .reviewignore. No validator failed because of the orphan checkout in .build. All 3 acceptance items are [x]. Each named test is in the tests: aMetadataTitleStaysAfterTheProgressTheReportAndTheSettlement, aRunWithNoMetadataTitleShowsItsOp (ToolDisplayProjectionTests.swift), theSdkCallDoesNotWriteItsNameOverAMetadataTitle (ToolCallJoinProjectionTests.swift), theRunCodeCallReachesTheWire (TranscriptFidelityTests.swift), and lastWireTitle(ofToolCall:) (Support/ProjectionTestSupport.swift).
    - next: none. The task is in done.
  timestamp: 2026-10-10T17:14:59.353641+00:00
- actor: claude-code
  id: 01m4kczg2qfwh2cq8kqvn4m7jf
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files; 3/3 acceptance items marked with their tests
    - test: green — swift test 874 (1 known issue); IntegrationTests 30
    - commit: 506c7c1
    - review: clean — 0 findings; every validator finished; each acceptance item names a test that exists
  timestamp: 2026-10-10T17:15:11.831235+00:00
depends_on:
- 01M4GH55FEFKK2JACVVE1YQ4GH
position_column: done
position_ordinal: ffb780
title: 'Keep the title that a tool gives its call: later run updates must not write the op title again'
---
## Problem

Task ^a6mndxz sends a `.metadata` display event of a tool as a `tool_call_update` patch with the title of the tool (for example "Edit /repo/notes.txt"). Each other update of the run also sends a title: `EventProjection.runCallUpdate` gets `title: .value(op)` from the progress, the attachment report, the settlement and the display content replace. The settlement is always the last update of a run. Thus the client shows the `op` ("edit file") again after the run, and the title of the tool is lost.

## Why the run updates send the op title

Each run update can be the creation of the wire call, because the run call is keyed on the completion token and nothing else creates it. Task ^e1yq4gh changes the key of the run updates to the joined SDK tool-call id. After ^e1yq4gh, the SDK `toolCall` event (or the open invocation record) can be the one creation, and the later run updates can omit the title.

## What to change

- Do this task after ^e1yq4gh.
- Send the `op` title only on the update that creates the wire call. Omit the title on each later run update, so that a title from a `.metadata` display event stays.
- Note: the SDK `toolCall` creation arrives after the SDK call returned, thus after the display events of the call. It must not write its title over a title that a `.metadata` event already sent.

## Acceptance

- [x] A run that sends a `.metadata` title, then progress, a report and a settlement, ends with the title of the tool on the client. Proof: `Tests/FoundationModelsACPAgentTests/ToolDisplayProjectionTests.swift` `aMetadataTitleStaysAfterTheProgressTheReportAndTheSettlement`; for a joined SDK call with the SDK events at the end: `Tests/FoundationModelsACPAgentTests/ToolCallJoinProjectionTests.swift` `theSdkCallDoesNotWriteItsNameOverAMetadataTitle`.
- [x] A run with no `.metadata` title still shows the `op` (or the tool name) as its title. Proof: `Tests/FoundationModelsACPAgentTests/ToolDisplayProjectionTests.swift` `aRunWithNoMetadataTitleShowsItsOp`; for a real scripted run: `Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift` `theRunCodeCallReachesTheWire`.
- [x] A test reads the wire messages for both cases. Proof: `aMetadataTitleStaysAfterTheProgressTheReportAndTheSettlement` and `aRunWithNoMetadataTitleShowsItsOp` (`Tests/FoundationModelsACPAgentTests/ToolDisplayProjectionTests.swift`), and `theSdkCallDoesNotWriteItsNameOverAMetadataTitle` (`Tests/FoundationModelsACPAgentTests/ToolCallJoinProjectionTests.swift`), read the JSON-encoded wire updates through `[SessionUpdate].lastWireTitle(ofToolCall:)` in `Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift`.
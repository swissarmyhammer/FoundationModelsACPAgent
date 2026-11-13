---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m78zwfr4m4qnzsjn8skxrgdx
  text: |-
    Research (implement step).
    - Cause: `redriveInterruptedRuns` calls `workStarted(on:)` on the ledger of each restored run only AFTER `syncChildren`. Thus the snapshot (`currentSnapshot()`) and the own `state_update` (`announceCurrentState()`) of each restored child say idle with noWork, and `running` comes later.
    - The root (the caller of the child) has the same fault. Router opens a `claimedRun` lease on the restored root before the projector listens, so the ledger of the root does not see the start. Thus the root sends idle with noWork before the response (frame 7 of killed-run2.txt) and again with background [child] (frame 15). The decision says that a parent that waits is not idle with noWork either, so the fix must also cover the callers of the restored runs.
    - A `workStarted` call before the sync would deadlock: the ledger send of a child goes through its closed announcement gate, and `submit` waits until the gate opens. The ledger needs a mark that sends nothing. The current-state sync then reports the state.
    - The book of a parent lists a child only after `subagentAnnounced`, so a child activity before the announcement does not cause a send on the parent.
    - The existing test `ResumeChildSyncTests.aColdRestoredChildIsIdleInItsSnapshot` (from ^7wta3jt) asserts the old behavior. The decision of testudoapp-75 replaces that behavior, so that test changes. `theRootAfterAShutdownReportsNoCompletedPrompt` asserts exactly one root idle before the response. That test also changes: the root now sends running there, with no stop reason.
  timestamp: 2026-11-12T23:01:02.852678+00:00
- actor: claude-code
  id: 01m790e0xjanjeckv3evkq59fk
  text: |-
    Implementation.
    - TDD: new suite `RestoredRunStateTests` (16 cases). RED before the fix: 10 issues (snapshot of child and grandchild was idle, first own state was idle, root states said idle with noWork; for shutDown and kill). The no-work tests passed before and after the fix.
    - Fix: new ledger mark `SessionStateLedger.restoredWorkHeld(on:)` and its inverse `restoredWorkReleased(on:)`. These marks send nothing (a send of a child would wait for its closed gate). The ledger takes the state as reported, and tells the parent the activity.
    - `holdRestoredWork(of:)` (SessionResumeRedrive.swift) marks each restored run and each caller of a restored run (`RestoreReport.heldSessions`) before `syncCurrentState` of the root. Thus the root state before the response, the snapshots and the own states of the children are `running`.
    - `redriveInterruptedRuns` does not call `workStarted` any more. When it does not start the runs (root closed, or no connection), it calls `releaseRestoredWork(of:)`. The resume also releases the hold when no connection path exists at the response.
    - The end of the work comes from Router as before: the test `theRootSaysIdleWithNoWorkWhenTheRedrivenRunsEnd` shows that the root, the child and the grandchild end idle with noWork and an empty background.
    - Changed old tests per the decision of testudoapp-75: `ResumeChildSyncTests.aColdRestoredChildIsIdleInItsSnapshot` is now `aColdRestoredChildThatRunsAgainIsRunningInItsSnapshot`; `theRootAfterAShutdownReportsNoCompletedPrompt` now expects the one root state before the response to be `running`.
    - Docs: README resume steps 3 and 4, and the doc comments in SessionResumeChildSync.swift and SessionResumeNested.swift.
    - Open: acceptance item 3 (foundationmodelsacpclient-76 confirms 10 of 10) needs a push. This step did not commit, as instructed.
  timestamp: 2026-11-12T23:10:37.490668+00:00
- actor: claude-code
  id: 01m790e58a13j3xqg4xr9sk99x
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsACPAgent/Agent/PromptState.swift, Sources/FoundationModelsACPAgent/Agent/SessionResumeRedrive.swift, Sources/FoundationModelsACPAgent/Agent/SessionResume.swift, Sources/FoundationModelsACPAgent/Agent/SessionResumeNested.swift (doc), Sources/FoundationModelsACPAgent/Agent/SessionResumeChildSync.swift (doc), README.md, Tests/FoundationModelsACPAgentTests/RestoredRunStateTests.swift (new), Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift. `swift test`: 2038 tests in 222 suites passed, 0 failures, 1 known issue (existing HarnessSmokeTests withKnownIssue), 0 compiler warnings. `swift build --build-tests --package-path IntegrationTests`: Build complete. Targeted run after the last test-format edit: RestoredRunStateTests 6 tests passed; RestoredRunState + ResumeChildSync + RedriveInterruptedRuns + ResumeNestedSessions 48 tests passed.
    - next: /review. Acceptance item 3 waits for a push and the confirmation of foundationmodelsacpclient-76.
  timestamp: 2026-11-12T23:10:41.930900+00:00
- actor: claude-code
  id: 01m790m2z4dxrg5mwdfvth2dce
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD, 1 finding (1 confirmed, 7 refuted) — Sources/FoundationModelsACPAgent/Agent/PromptState.swift:257
    - next: implement the open finding, then review again.
  timestamp: 2026-11-12T23:13:56.196646+00:00
- actor: claude-code
  id: 01m799ayxza8tfp2tr540cts5w
  text: |-
    ### review — clean
    - evidence: review sha 6bcc3b1~1..6bcc3b1, 0 findings (0 confirmed, 0 refuted, 7 attempted). Commit 6bcc3b1 adds noteReported(_:), and deliverChange() and takeUnsentChange() both call it. The guard is one time in forgetPromptEnd(leaving:entering:). Thus the finding of 2026-11-12 18:11 at PromptState.swift:257 is fixed and is now checked.
    - next: none. The task is in done. The acceptance criterion for the confirmation from foundationmodelsacpclient-76 stays open.
  timestamp: 2026-11-13T01:46:14.335843+00:00
- actor: claude-code
  id: 01m79m2dxs9ctjpjvabyrkbx92
  text: 'Acceptance confirmed by foundationmodelsacpclient-76 (2026-11-12): 20 of 20 full integration runs passed on ACPAgent 74eea0a and FoundationModelsACP 9254159, with the idle end on the resume waits (ACPClient 4a53c2d). anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall 20/20, aKilledAgentResumesTheNestedRunWithItsTree 20/20.'
  timestamp: 2026-11-13T04:53:49.113795+00:00
position_column: done
position_ordinal: ffffe180
title: A restored run that will continue is announced idle with noWork after a cold resume
---
## What
Report of foundationmodelsacpclient-76 (2026-11-12), on ACPAgent 0c1aeaf. After a cold `session/resume` of a tree with an interrupted nested run (orderly quit or kill), the snapshot after the response gives the child and the grandchild the state `{"state":"idle","_meta":{"noWork":true},"background":[]}`. Then the grandchild sends `state_update` idle, and some frames later `state_update` running, because the restored run continues (redrive). Example (killed run 2, second connection): 12 `subagent_update(grandchild)` idle noWork; 13 grandchild `state_update` idle; 16 grandchild `state_update` running. Traces: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsACPClient/c6a2f1c1-d86c-4e3e-8e84-1327458d50a2/scratchpad/runs10e/ (killed-run2.txt has one dump).

`NoWorkIdle.swift` says that the agent sends idle with `noWork` only when the session has no work at all. A restored run that the agent will re-drive is work. Thus this snapshot is wrong, and a client cannot tell it from a real end. With a client wait that ends on idle, the ACPClient resume tests fail 9 of 10.

1. Reproduce it in this package with a deterministic test: record a tree with an interrupted nested run, restore it in a new agent, and read the snapshot of the child and the grandchild after the response.
2. Fix: a restored run that the agent will re-drive (`redriveInterruptedRuns`, `SessionResumeRedrive.swift`; `restoreNestedSessions`, `SessionResumeNested.swift`) is announced as `running` (or at least not idle with `noWork`) from the snapshot on, and it sends no `idle` before its `running`. The parents that wait for it are also not idle with `noWork` (their background lists the run).
3. Tell foundationmodelsacpclient-76 when it is pushed; it then puts the idle end back on its resume waits.

## Acceptance Criteria
- [x] After a cold resume, the snapshot of a restored run that will continue is not idle with noWork, and no idle state_update comes before its running.
- [x] A session with really no work still gets idle with noWork.
- [ ] foundationmodelsacpclient-76 confirms its resume tests with the idle end pass 10 of 10.

## Tests
- [x] A deterministic test in this package that fails before the fix and passes after it.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1

## Review Findings (2026-11-12 18:11)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Agent/PromptState.swift:257` `reuse/reuse` — `takeUnsentChange()` repeats the reported-state bookkeeping of `deliverChange()` and `update(entering:from:)`: it leaves idle, drops the last prompt end through `forgetPromptEnd(after:)`, and sets `reported`. The logic is written a second time instead of being shared, so a later change to the idle bookkeeping has to be made in two places. Pull the shared step (`forgetPromptEnd(after: reported)` followed by `reported = next`) into one helper that both `deliverChange()` and `takeUnsentChange()` call. Keep the send-only part in `deliverChange()`. If the guard is needed, put it inside `forgetPromptEnd` once, since it already checks `previous == .idle`.

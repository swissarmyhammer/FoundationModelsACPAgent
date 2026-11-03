---
comments:
- actor: claude-code
  id: 01m6h1343hnat4wdve6dpn8g01
  text: |-
    implement: changed. The resume now sends the current-state sync for every resume, with or without replayFrom: replay (if any), then one current state_update, then session_info_update, then the response.

    Files: Agent/PromptState.swift (SessionStateLedger.currentSnapshot(waitingForUser:) and announceCurrentState(waitingForUser:); same actor and sink as the changes; idle snapshot has no stop reason and no error, so it announces no completion or cancellation). Agent/SessionHistory.swift (replayUpdates keeps the retained state_update out of the replay; sessionInfoSyncUpdate(recordedTitle:); SessionUpdate.isStateUpdate). Agent/SessionResume.swift (syncCurrentState(of:) called after replayHistory). Agent/ElicitationRelay.swift (isWaitingForUser; a relayed copy, found by a non-empty agentPath, does not count, so a relayed copy never makes the root requires_action). New tests: Tests/FoundationModelsACPAgentTests/ResumeSyncTests.swift (14 tests).

    Old tests updated because they asserted the old behavior: SessionHistoryTests.theReplayFromTheStartSendsTheFullHistory (no stateUpdate in the replay); PromptExecutionTests.aResumeWhileAPromptIsOpenEndsThatPromptCancelledFirst (the resume now adds one idle snapshot: 2 idles at the resume, wait for 3); SessionOwnerTests.theRequestsOfASessionGoToItsOwnerAndOnlyAUserDeviceTakesIt (the taker gets the idle snapshot first, so it waits for 2 idles).

    Router isRelayed is internal, so the relay uses the public agentPath (non-empty only when a relay set it).

    Known limit, not in this card: the live path still sends no requires_action (the ledger sends only running and idle). So a requires_action snapshot has no later change that ends it when the question is answered. A follow-up card covers the live requires_action transitions. The background list of the sync (step 2 of the order) is for the background list task.

    Tests: swift test: 1333 tests, 146 suites, all passed (1 known issue that was there before). swift test --filter ResumeSyncTests: 14 tests passed. Note: the two relay tests (isWaitingForUser) were added after the code, not before.
  timestamp: 2026-11-03T15:40:22.513954+00:00
- actor: claude-code
  id: 01m6h1ezwn7ywwrk66pmpqc2nt
  text: 'review: findings. 10 open items in the new Review Findings section: 3 from the engine (test helper copies in ResumeSyncTests.swift:85, 93, 101) and 7 from the hand check (requires_action with no exit, snapshot race through the reentrant ledger, a race test that cannot fail, running snapshot with no real path, no test of the order against the response, an empty session_info_update, the snapshot that replaces the retained idle stop reason, long comment sentences). Task stays in review.'
  timestamp: 2026-11-03T15:46:51.413490+00:00
- actor: claude-code
  id: 01m6h2jgv2t4b7s6stn3vx477g
  text: |-
    implement: changed. All findings of the review list are fixed (11 checklist items). Root swift test: 1343 tests, 147 suites, all passed (1 known issue that was there before).

    What changed. SessionStateLedger (Agent/PromptState.swift) now sends every update through one serial turn queue (takeTurn, passTurn). So a later change never overtakes a snapshot or an earlier change. The ledger tracks three states: idle, running, requires_action. currentSnapshot() has no argument now. The snapshot goes to a second sink, announce. That sink sends and does not record into the history (new RoutedACPAgent.unrecordedSink in SessionHistory.swift). So the retained idle keeps its stop reason. The relay (ElicitationRelay) tells the ledger when a non-relayed question starts and ends. A relayed copy (agentPath not empty) sends nothing. The relay has no isWaitingForUser any more. The ledger is the one source, so the live changes and the snapshot agree. The sync skips an empty session_info_update. The comments are short STE sentences, and the claim that the review proved wrong is gone.

    Finding by finding.
    1 to 3 (reuse): ScriptedPromptFixture.isIdle is internal now. The tests call isRunningState and isRequiresActionState. The private copies are deleted.
    4 (requires_action with no exit): the live path ends it (see the follow-up card ^snb0qg4).
    5 (race): the serial turn queue.
    6 (race test): aSnapshotInFlightIsNotOvertakenByALaterChange uses a sink that holds its first update on a gate. It fails when the turn queue is removed (checked).
    7 (running snapshot has no real path): syncCurrentStateSendsRunningWhenTheLedgerIsBusy is named as a test of the function, and its comment says why (a resume ends open prompts and builds a new ledger). Real resume tests cover idle and the order. syncCurrentStateSendsRequiresActionWhileAQuestionWaits covers requires_action.
    8 (order against the response): the order tests read the wire lines with WireTap (Support/WireItem.swift) and check state, then info, then the response. PromptExecutionTests.aResumeWhileAPromptIsOpenEndsThatPromptCancelledFirst checks that both idle updates come before the response.
    9 (empty info): aResumeOfASessionWithNoInfoSendsNoSessionInfoUpdate. It fails when the guard is removed (checked).
    10 (retained idle): aResumeKeepsTheRetainedIdleWithItsStopReason. It fails when the snapshot is recorded (checked).
    11 (STE comments): done.

    Old tests changed because the behavior changed: the form, URL and cancel tests of ElicitationRelayTests, and two tests of PromptFollowUpTests. An open background question now reports requires_action until it ends.
  timestamp: 2026-11-03T16:06:15.650837+00:00
depends_on:
- 01M6GPCJ3CMS7YE71DQ3J33QC8
position_column: review
position_ordinal: '8180'
title: Resume sends the current-state sync (state_update snapshot, session info) after any replay and before the response, also without replayFrom
---
## What
ACP v2 `session/resume` has a fixed order (v2 Session Setup, "Ordering"): (1) replay the requested history, if any; (2) for each item of the `background` list that the replay did not deliver at its current state, send a current `terminal_update`, `tool_call_update` or `subagent_update` (see the background list task); (3) send a CURRENT `state_update` ("MUST send a current state_update after any requested history replay and before the resume response", also when no replay was requested); (4) send current session info with `session_info_update`, and optionally a current `usage_update`; (5) send the response, which carries the current `configOptions` and `availableCommands`. The client must not reset the state to idle when the response arrives. The agent must not send a current update for an entity that the replay already covered at its current state.

Today (read in the code, not run):
- `replayHistory` in `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` (near line 471) returns at once when there is no cursor. A resume with no `replayFrom` sends no sync.
- With a cursor, `replayUpdates(from: .start)` (`Agent/SessionHistory.swift`, near line 150) sends `transcriptUpdates + stateUpdates`. `stateUpdates` (FoundationModelsACP `Session/SessionMergeEngine.swift`, near line 257) includes `agentState`, the RETAINED last `state_update`. Historical state updates must not be replayed as current activity.
- `SessionStateLedger` (`Agent/PromptState.swift`, near line 48) sends only changes. It cannot give its current state on demand.

Do:
1. Add `SessionStateLedger.currentSnapshot()`: `running`, `requires_action` (a prompt or a request waits for the user), or `idle` (the last stop reason for context only). It uses the same actor and sink as the changes, so a snapshot never overtakes a newer change.
2. In the resume path send the snapshot and `session_info_update` after the replay (or at once when there is none), then the response. Keep the retained `agentState` out of the replay path.
3. The sync runs for every resume, with or without `replayFrom`. Without `replayFrom` the agent sends no history.
4. An idle snapshot announces no new completion or cancellation.
5. Do not change FoundationModelsACP or the client from this task. The `background` items of step (2) are added by the background list task.

## Acceptance Criteria
- [x] With `replayFrom: start` the wire order is: replay, then one current `state_update`, then `session_info_update`, then the response.
- [x] With no `replayFrom` there is no history, and the current `state_update` and `session_info_update` still come before the response.
- [x] The snapshot shows `running` when the ledger is busy and `requires_action` when a question waits, and `idle` otherwise. A resume ends each open prompt, so a resume starts idle. A recorded old `running` is never sent as current.
- [x] No retained `state_update` is in the replay.
- [x] A snapshot never overtakes a newer state change.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ResumeSyncTests.swift`: order with and without a cursor, running and idle snapshots, no retained state in the replay, ordering under a concurrent change.
- [x] Run `swift test --filter ResumeSyncTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-11-03 09:40)

> Scope: `review working` — reviewed the diffs only. Engine counts: 3 findings, 2 refuted. Findings 4 to 10 come from a hand check of the ordering, the race, the tests and the relay rule.

- [x] `Tests/FoundationModelsACPAgentTests/ResumeSyncTests.swift:85` `reuse/reuse` — The new private `isIdle(_:)` repeats the check already done by `ScriptedPromptFixture.isIdle`. Two copies of the same check will drift apart. The copy in `ScriptedPromptFixture` is private, so the fix must also widen its access. Remove the private `isIdle` from `ResumeSyncTests` and call one shared helper. Make `ScriptedPromptFixture.isIdle` internal, or move it to `ProjectionTestSupport.swift` next to the other state readers. Use the shared helper here.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeSyncTests.swift:93` `reuse/reuse` — The new private `isRunning(_:)` repeats `isRunningState` in `ProjectionTestSupport.swift`. The only difference is the input type: it takes a `StateUpdate` where the existing helper takes a `SessionUpdate?`. Call `isRunningState(.stateUpdate(state))` instead of the private `isRunning`, or add a `StateUpdate` overload next to `isRunningState` and have both call it. Delete the private copy.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeSyncTests.swift:101` `reuse/reuse` — The new private `isRequiresAction(_:)` repeats `isRequiresActionState` in `ProjectionTestSupport.swift`. It differs only in input type. Call `isRequiresActionState(.stateUpdate(state))`, or add a `StateUpdate` overload beside it and have both call one implementation. Delete the private copy in `ResumeSyncTests`.
- [x] `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift:508` `correctness` — The sync can send `requires_action` and nothing ends it. The ledger sends only `running` and `idle`, and `sentRunning` stays false when the session is not busy. So when the user answers the question, no later change reaches the client, and the client keeps `requires_action` until the next prompt starts. The card text says the client must not stay in a wrong state. Make the answer of the question (or the end of the wait) send a current state, or do not send `requires_action` from the sync until the live path ends it. Do not leave a state that has no exit.
- [x] `Sources/FoundationModelsACPAgent/Agent/PromptState.swift:161` `correctness` — The comment says that "a later change is sent after it". The code does not prove this. `announceCurrentState` suspends on `await send(...)`, the ledger actor is reentrant, so a later `sendChange` can call the sink while the snapshot send is still in flight (the sink hops to the agent actor in `recordInHistory` and then posts). The two sends can then reach the client in the other order, and an old `idle` can follow a newer `running`. Serialize the snapshot and the changes (for example one ordered queue in the ledger that the sink drains in order), or change the claim and the acceptance criterion. Do not keep a claim that the code does not hold.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeSyncTests.swift:177` `tests/tests` — `aSnapshotNeverOvertakesANewerChange` cannot fail. The `RecordingSink` appends with no suspension, so the reentrancy race of the previous finding can never show. In both orders of the `async let` pair the last state is `running`, and the second check reads a ledger after `promptStarted` ended, which is always `running`. Use a sink that suspends (for example one that waits on a gate for the first update) and start the change while the snapshot send waits. The test must fail when the snapshot overtakes the change.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeSyncTests.swift:294` `tests/tests` — `theSyncSendsRunningWhenAPromptIsOpen` calls `syncCurrentState` directly on a live session that has a prompt opened on its ledger by hand. No resume reaches this state: `restoreSession` tears down the old entry (open prompts end as `cancelled`) and builds a new entry with a new ledger, so at the response of a resume the ledger is busy only when Router work or a new prompt starts in the gap. The acceptance criterion "running when a prompt is open at the resume" has no test through `session/resume`, and no real path is shown. Add a test of a real path (for example Router work that runs at the resume, or a prompt that arrives between `activateSession` and the sync), or change the criterion to say that a resume always starts idle.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeSyncTests.swift:230` `tests/tests` — The two wire-order tests read the updates only after `resumeSession` returned. They do not check that the `state_update` and the `session_info_update` come BEFORE the response, which is the main rule of the card. The same hole is in `PromptExecutionTests.aResumeWhileAPromptIsOpenEndsThatPromptCancelledFirst` (`atResume` is read after the response, and its doc says "before the response"). Record the position of the response in the same sequence as the updates, or send the updates through a client that notes the response, and assert the order. Also no test sends `requires_action` through a resume: the relay tests read `isWaitingForUser` only, so the `syncCurrentState` call of `isWaitingForUser` has no test.
- [x] `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift:509` `correctness` — The sync always sends `session_info_update`, also when the history has no info and the Router record has no title. The replay path skips an empty `SessionInfoUpdate()` (`stateUpdates` in FoundationModelsACP). An empty update on the wire is a change in behavior with no value. Send the info only when it is not equal to `SessionInfoUpdate()`, or show in a test that the empty update is wanted by the ACP rule.
- [x] `Sources/FoundationModelsACPAgent/Agent/PromptState.swift:161` `design` — The snapshot goes through `historySink`, which calls `recordInHistory` first. The idle snapshot (no stop reason) therefore replaces the retained `agentState` of the history, and the history file loses the stop reason of the last prompt. The comment of `currentSnapshot` says the snapshot "changes nothing". Send the snapshot to the connection only (not to the history), or keep the retained `idle` with its stop reason, and add a test that reads the retained `agentState` after a resume.
- [x] `Sources/FoundationModelsACPAgent/Agent/PromptState.swift:157` `clarity/ste` — The doc comment of `announceCurrentState` has one sentence of 38 words with a colon and two clauses ("The snapshot is read and sent without a suspension between the two, on the actor of the changes: a change that the ledger took before is in the snapshot, and a later change is sent after it."), and the second half is not true (see the finding of the race). The `isWaitingForUser` and `syncCurrentState` comments also hold sentences of more than 25 words. Split each of them into short sentences with one idea, and keep only claims that the code holds.

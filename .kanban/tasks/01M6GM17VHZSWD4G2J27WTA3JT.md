---
comments:
- actor: wballard
  id: 01m6gmvg34rqv9sv0ccbhh5qjc
  text: |-
    PLAN REVIEW FIX (2026-11-03). The description above is correct except where this comment corrects it; where they conflict, this comment wins and the description is to be rewritten before the task starts.
    A child listed in the parent background list needs a subagent_update BEFORE the parent snapshot (background list rule), and that snapshot is before the response. Send that one pre-response update; the client keeps the child unconfirmed. The post-response snapshot confirms it. Add a hot resume test with a running child. Also announce a child that FAILED to restore as state unknown with a reason (user decision), with no capabilities.
  timestamp: 2026-11-03T12:06:29.732832+00:00
- actor: wballard
  id: 01m6gns7ztr4cq8nas3r5jgxcq
  text: |-
    DECISION (user, 2026-11-03): if an agent session is DONE, there is nothing to restore. When an agent finishes, its session is ended and removed. Agents runs stay ONE-SHOT (no idle state in AgentRunState).
    EFFECT ON THIS PLAN:
    - A resume restores ONLY the sub-agents that were still working (interrupted) when the process stopped. Finished children are not restored and are not announced as part of the restored tree.
    - The set to restore is the set of orphan runs of the parent (a run with a non-terminal journal event and no completed). This is the same set that the Router claim card (01M6GK8K45DRDT6B4SHB9V60ED) lets a host claim. The two tasks are one flow: claim, restore, continue, complete the original call.
    - This replaces: "restore every recorded sub-agent session, found through agentSpawn.parentSessionId, all idle" (cold resume), and "a restored child comes back idle and can get new work later". A restored interrupted child is announced idle in the first snapshot after the response, then goes running when it is continued (re-drive), after the response. It ends once; then it is removed like any finished child.
    - The Agents restore API (card 01M6GNHC0MV9FBT33Z9DTT5TVA on the Agents board, rewritten) restores and continues in one call.
    - To verify first: how the host finds the child session of an orphan run after a crash (orphan RunKey -> SDK tool call id in the journal -> recorded child with agentSpawn.parentToolCallId). The runner map from completion token to run is in memory and is lost in a crash.
    - Open (the user decides): how the live ACP tree tells the client that a finished child is gone. ACP has no removal message; a child stays an idle association.
  timestamp: 2026-11-03T12:22:44.474879+00:00
- actor: wballard
  id: 01m6h07p647y010z6nja5mjd7q
  text: |-
    DECISION (coordinator, 2026-11-03), failed children on resume:
    1. A child that FAILS to restore is announced with a subagent_update: state unknown, no capabilities, and `_meta.sah.restoreFailure = { reason }` (typed wire payload SAH.RestoreFailure, being added by the ACP session; send the full `sah` object, since _meta patches by top-level key).
    2. Each DESCENDANT of a failed child is announced the same way (unknown, parent before child), with the reason "an ancestor was not restored". They cannot be restored because their caller is not restored.
    3. The client clears restoreFailure when a later current subagent_update with a state arrives. A silent agent (no current snapshot after the response) is NOT a failure: the child stays unconfirmed (unknown, controls disabled). The client has no timer.
    4. The original call of the failed child ends as lost (the Router claim API closes an open claim as lost).
    Add acceptance criteria and a test for items 1 and 2 (a failed child and its descendants announced unknown with the reason, the root still resumes).
  timestamp: 2026-11-03T15:25:23.524276+00:00
- actor: wballard
  id: 01m6h6km00q0wtj21jyppj8fqw
  text: 'SPEC REVIEW (independent, 2026-11-03): the resume has no work after the response today: no current subagent_update for any child. The only child updates a client gets are the replayed ones. This task supplies them: after the response send a current subagent_update (state and capabilities) for every live child, parent before child, before any re-drive. See the replay task for the rule that a replay carries no capabilities.'
  timestamp: 2026-11-03T17:16:45.952149+00:00
- actor: claude-code
  id: 01m6kbhakkxbw8g62zhgxcjgqp
  text: |-
    ### implement — stuck
    BLOCKER (true conflict, rule 8 of the wire validator vs this task).

    Group A (fixed): SubagentSessionsReplayTests `resume` helper now reads the wire with `subscribeToAllSessions()` and keeps only the updates BEFORE the resume response marker. All original assertions and preconditions stay. The post-response sync is checked by ResumeChildSyncTests, so no new assertion was added. `swift test --filter SubagentSessionsReplayTests`: 13 tests pass.

    Group B (open): ResumeChildSyncTests `theWireOfTheResumeFollowsTheRulesOfTheValidator(replays: true)` and `theWireOfAResumeWithAFailedChildFollowsTheRulesOfTheValidator(replays: true)` fail. The cases with replays false pass.

    The two rules:
    1. Validator rule 8, .build/checkouts/FoundationModelsACP/Sources/FoundationModelsACP/Session/SubagentWireTraceValidator.swift: `finished` (set at applyToolCall, final status completed/failed/cancelled) is never reset at the response; applySubagent reports "a subagent_update of <child> after its final tool call" and applyUpdate reports "an update in <child> after its final tool call". The doc SubagentSessions.md says: "A client removes the child at that [final tool_call_update] update". The validator has no option for a resume trace.
    2. This task, acceptance criterion 1 and Do step 1: after the response every child of the tree gets a current subagent_update and its own state_update. Validator rules 3 and 5 force the child to be announced before the response when its history is replayed.

    The conflict: the recording of `recordInterruptedChain` holds a FINAL (cancelled) status for the root `agents` call, so the replay (history, not changed) sends that final status before the response. The restored child is a live session, and the task requires its current snapshot after the response. Rule 8 reports every such send: chain case positions 12-15; failed-child case position 3 (a failed child has no state by rule 10, so no idle state can precede the final status) and positions 10-11.

    What I checked:
    - The resume response does not reset rule 8; a resume request resets the whole run (`apply(.resumeRequest)`), so there is no valid split of the trace.
    - Code cannot satisfy both without a decision: skipping the snapshot of a child whose `agents` call is final in the replayed history breaks acceptance criterion 1; changing the replayed status is falsifying history; feeding the validator only a part of the trace removes the check.
    - Note for the decision: the user decision (2026-11-03) says only interrupted children (orphan runs, no final status) are restored, and finished children are not restored or announced. Under that rule a restored child has no final status in history. The current fixture (quit cancels the runs and records a final status) and the agentSpawn-based restore do not match that rule. The right fix may be the orphan-run restore card, or a corrected fixture that records no final status for an interrupted call, or a rule change in the validator. A person must choose.

    The two tests are left as they are, nothing is skipped. Task stays in doing. Full `swift test`: 1704 tests, 3 unexpected issues: these 2 tests, and the known ShellSessionOwnerTests.aCommandAfterAModelSlotSwitchRecordsTheACPSessionID (peer commit not yet in tree); plus the intentional HarnessSmokeTests known issue. The last acceptance box ("Run swift test --filter ResumeChildSyncTests. All pass.") stays unticked.
    - evidence: files changed this pass: Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift
    - next: a person decides the conflict.
  timestamp: 2026-11-04T13:21:22.547928+00:00
- actor: claude-code
  id: 01m6kfv420nkctdrgn2fk2ks2z
  text: 'DECISION NOTE (2026-11-04), option (a), from the user via the coordinator: the validator rule 8 stays as it is. A child whose linked `agents` call has a FINAL status in the replayed history is not restored as a live child. It gets no post-response subagent_update and no state_update. Its history only replays before the response. A child whose call has NO final status is interrupted. It is restored, and it gets its current subagent_update and state_update after the response. Acceptance criterion 1 now says "each restored (interrupted) child".'
  timestamp: 2026-11-04T14:36:37.824207+00:00
- actor: claude-code
  id: 01m6kfxss3j6v4hqv6ksxrae48
  text: |-
    ### implement — changed
    - evidence: full `swift test`: 1756 tests, 191 suites, pass, 1 known issue (HarnessSmokeTests, intentional). ShellSessionOwnerTests passes. Filtered: ResumeChildSyncTests, ResumeNestedSessionsTests, SubagentSessionsReplayTests, ChildSessionUsageTelemetryHooksTests all pass. Last box ticked.
    - files: Sources/FoundationModelsACPAgent/Agent/SessionResumeChildSync.swift (rule 1: `SessionMergeEngine.endsCall(of:)`; the sync skips a child whose linked `agents` call has a final status, and its descendants), Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift, Tests/FoundationModelsACPAgentTests/ResumeNestedSessionsTests.swift, Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift, plus the earlier SessionResume.swift and SessionHistory.swift changes.
    - TDD: 3 new tests failed first (2 for rule 1, 1 for the open call), then passed.
    - FINDING (directive 3 premise is false): an orderly `agent.shutdown()` DOES cancel the root `agents` call. Cause: `tearDownSession` (SessionLifecycle.swift) cancels every open prompt first (`entry.session.cancelAll()` and `waitForPromptEnd()`), also when `isShutdown` is true. Only the agent runs are stopped and not cancelled. The root prompt is open while the child works, so the translator records a `cancelled` final status for the `agents` call in the root history, and the history file is written with it. I saw it in the collector: the cancelled `tool_call_update` appears during `shutdown()`. The commit message of 7444132 says the shutdown does not cancel the root prompt: that is true for the runs, not for the open prompt. Effect with rule 1: after a real shutdown with an open root prompt, the call of each child is final, so no child is restored as live. The interrupted-child restore works only after a hard kill. A person must decide if the shutdown must keep the open prompt call open (change in SessionLifecycle, outside this task).
    - Deviation from directive 3: I could not write a test that proves the `agents` call stays open under the real shutdown, because it does not. Instead: (a) `recordShutDownChain` (real shutdown) is the fixture of the two rule-1 tests, so they show the real path gives no snapshot; (b) `recordInterruptedChain` is now a hard-kill fixture: it writes the history of each session as the end of a prompt writes it (`writeHistory(of:)`), suspends the sessions, never closes the first agent, and does not wait for the prompt; (c) the test `aHardKillKeepsTheAgentsCallOpenAndTheResumeWireIsValid` proves the replayed `agents` calls have no final status and the wire passes SubagentWireTraceValidator (with replay). The history flush mid-prompt is a test construct; production writes the file only at prompt end and at close.
    - Earlier tests changed: SubagentSessionsReplayTests now uses `recordShutDownChain` (it had it in HEAD as the only user; the name stays, the helper is back after I removed a duplicate). ResumeNestedSessionsTests: `childAgent` visibility only, and `recordChain` got the parameter `endsPrompt`. No assertion weakened, no test skipped. The validator tests (ChildSessionProjectionTests) are unchanged and pass.
    - next: review.
  timestamp: 2026-11-04T14:38:05.603483+00:00
- actor: claude-code
  id: 01m6kgdkexqcgp7abasseq0xjt
  text: |-
    ### review — findings
    - evidence: review sha 3c7ae4b~1..3c7ae4b. 10 findings (10 confirmed, 5 refuted). 7 pairs attempted, 0 failed, 0 skipped. Open: SessionResumeChildSync.swift:112, SessionResumeChildSync.swift:156, ResumeChildSyncTests.swift:106, :130, :237, :255, :501, ResumeNestedSessionsTests.swift:87, SubagentSessionsReplayTests.swift:110, :118.
    - next: the implementer fixes each finding, then runs /review again.
  timestamp: 2026-11-04T14:46:43.421545+00:00
- actor: claude-code
  id: 01m6kgt2ad6kd20jf3xpj1fpt1
  text: |-
    ### implement — changed
    - evidence: filtered `swift test --filter "ResumeChildSyncTests|ResumeNestedSessionsTests|SubagentSessionsReplayTests"`: 41 tests, 3 suites, pass. Full `swift test` (foreground): 1756 tests, 191 suites, pass, 1 known issue (HarnessSmokeTests, intentional). No other issue. One build warning exists in AgentTranscriptWiringTests.swift (redundant #require), not in this commit.
    - findings fixed (10 of 10, boxes flipped to [x]):
      - SessionResumeChildSync.swift:112: `assertionFailure("The restore failure of a child did not encode: \(error)")` before the log. Only one catch in the file.
      - SessionResumeChildSync.swift:156: `currentUpdate(of:)` in SessionHistory.swift now calls `announced(_:)`. One subagent lookup remains. Also the shared helper for the final-call match: new `SessionUpdate.endedChild` (SessionResumeReplay.swift) is used by `ReplayedSession.child(endedBy:)` and by `endsCall(of:)`.
      - ResumeChildSyncTests:106 and :130: one predicate pair on `WireTraceEvent` (`isOwnState(of:)`, `announces(_:)`), built from `SessionUpdate.announces`. `Wire.ownState(of:)` uses it. The two static closure helpers are gone. `Sent` got `event`, and `announcement` uses `SessionUpdate.announcement` (one match of that case in the file).
      - ResumeChildSyncTests:237: new `secondAgent(for:)` and `resumeWithoutWire(_:)`. `resume`, `resumeWithoutSync` and `syncOfTheShutDownChain` use them.
      - ResumeChildSyncTests:255: `startWork` returns the task handle. Each test cancels it in `defer` and awaits it after the sync.
      - ResumeChildSyncTests:501: `try #require(update?.announcement)`. The same early-return `guard` in the running-snapshot test is gone too (`try #require` and `#expect`).
      - ResumeNestedSessionsTests:87: new `suspendAll(of:)`, used by `quit(_:)` and `recordInterruptedChain`.
      - SubagentSessionsReplayTests:110 and :118: new test support `SessionEventSubscription.readResumeTrace(startingWith:settledBy:)` (Tests/FoundationModelsACPAgentTestSupport/WireTraceReading.swift). Both suites call it. It has no `default` switch.
    - No behavior change in production, no assertion weakened, no test skipped.
    - files: Sources/FoundationModelsACPAgent/Agent/SessionResumeChildSync.swift, Sources/FoundationModelsACPAgent/Agent/SessionResumeReplay.swift, Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift, Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift, Tests/FoundationModelsACPAgentTests/ResumeNestedSessionsTests.swift, Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift, Tests/FoundationModelsACPAgentTestSupport/WireTraceReading.swift (new)
    - next: /review
  timestamp: 2026-11-04T14:53:31.853571+00:00
- actor: claude-code
  id: 01m6kh27f3a3bvch9ka8ycek9q
  text: |-
    ### review — stuck
    - evidence: `review sha d4bc35f~1..8897e2d`, 2 findings (1 confirmed conflict, 1 open): SessionResumeChildSync.swift:112, SubagentSessionsReplayTests.swift:67
    - conflict: `swift/preconditions` (earlier finding, fixed) requires `assertionFailure` at SessionResumeChildSync.swift:112. `completeness/public-output-contract` requires its removal. A person must correct a rule.
    - next: a person decides which rule is correct. The finding at SubagentSessionsReplayTests.swift:67 stays open.
  timestamp: 2026-11-04T14:57:59.267035+00:00
- actor: claude-code
  id: 01m6kj5bks6hx5gkz5k0j0f01f
  text: |-
    ### implement — changed
    - Item A (SessionResumeChildSync.swift:112): no conflict. The old finding text was NOT damaged (it reads `assertionFailure("…: \(error)")`, one backslash), so no restore was needed. Rules read: `swift/preconditions` (unexpected recoverable condition gets assertionFailure AND log) and `completeness/public-output-contract` (no new hard failure on a recoverable path; no silent swallow). Design that satisfies both: the catch is removed. New `SAH.RestoreFailure.written(into:)` (SessionResumeChildSync.swift) writes `_meta.sah.restoreFailure` without a throwing step (the payload is one string), with the same merge rules as `inject(into:)`. `announceFailure` always sends the reason on the wire. No `assertionFailure`, no catch, no swallow. TDD: new `RestoreFailureMetaTests` failed first (no member `written`), then passed: 8 meta shapes equal `try inject(into:)`, and the reason reads back with `extract`.
    - Item B (SubagentSessionsReplayTests.swift:67): `SessionUpdate.announcement` and `announces(_:)` now live once in Tests/FoundationModelsACPAgentTestSupport/WireTraceReading.swift (public, because it is a separate module). The fileprivate copies in ResumeChildSyncTests.swift and the private `announcement(in:)` helper are deleted. Same cause removed from the whole file: the `guard case .subagentUpdate` match in `theReplayedAnnouncementCarriesTheIdleStateOfTheChild` now uses `try #require(announced.update.announcement)` and one `#expect` on the full idle state (stopReason and background nil kept).
    - The two boxes of the 08:54 review are ticked. The Blocker section is left as written (no rewrite beyond boxes); it is obsolete because the conflict is gone.
    - evidence: filtered `swift test --filter "ResumeChildSyncTests|SubagentSessionsReplayTests|RestoreFailureMetaTests|ResumeNestedSessionsTests"`: 43 tests, 4 suites, pass. Full `swift test` (foreground): 1758 tests, 192 suites, pass, 1 known issue (HarnessSmokeTests, intentional). No other issue. One build warning exists in AgentTranscriptWiringTests.swift (redundant #require), not from this work.
    - files: Sources/FoundationModelsACPAgent/Agent/SessionResumeChildSync.swift, Tests/FoundationModelsACPAgentTestSupport/WireTraceReading.swift, Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift, Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift, Tests/FoundationModelsACPAgentTests/RestoreFailureMetaTests.swift (new)
    - next: /review
  timestamp: 2026-11-04T15:17:10.393545+00:00
depends_on:
- 01M6GM0N9BFK37GGBWPAG9VE1X
- 01M6GH30709S58BK3AQ1VMBAM7
- 01M6GH3ZHE52GHWAZ53AWNKJ0K
position_column: doing
position_ordinal: '8480'
title: Resume announces the children and sends their current snapshots after the response, with or without replayFrom
---
## What
ACP "Subagent Sessions" RFD, resume rules for children:
- Children are announced (`subagent_update`) before any use of a child in live traffic, in parent-before-child order (the complete ancestor chain), also for a routing-only ancestor that was not restored (an association establishes identity, not a live runtime).
- With a replay: all history selected for the replay (associations and child history) is sent BEFORE the response. The response completes the best-effort child replay. The response is the freshness boundary: child work-state and capability snapshots sent before it are historical; CURRENT snapshots are sent AFTER the response.
- Without a replay: announcements, current snapshots and ordinary child traffic may come before or after the response, subject to announcement ordering.
- Agents SHOULD report the current child work state when they can determine it. Replay MUST NOT reissue permission or elicitation requests.
- A child state mirror on the parent (`subagent_update.state`) and the child own `state_update` must keep order: a delayed copy never overwrites a newer state.

Do (in the resume path of `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift`, after the shared child build of the first task):
1. After the response, send one current `subagent_update` for each child of the tree (state, capabilities, cwd) and, for a child that has its own session, its own current `state_update`. Cold-restored children: `idle`. Live children (hot resume): their real state.
2. The post-response sends happen before any re-drive and before any other live traffic of the same child.
3. With no `replayFrom`, still announce the children and send the snapshots (parent first).
4. Children are in the `background` list of their parent while running (background list task).
5. Do not change FoundationModelsACP or the client from this task.

## Acceptance Criteria
- [x] With a replay: no child current snapshot before the response; every restored (interrupted) child has a current snapshot after it; each parent is announced before its child.
- [x] Without a replay: children are announced and snapshotted, parent first.
- [x] A live running child (hot resume) shows `running` in its snapshot, not `idle`.
- [x] A snapshot of a child precedes any later `running` update of the same child.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift`: order with and without a cursor, a chain of three sessions, hot and cold, snapshot before re-drive.
- [x] Run `swift test --filter ResumeChildSyncTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents

## Review Findings (2026-11-04 08:38)

> Scope: `review sha 3c7ae4b~1..3c7ae4b` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 10 not reviewed.

> 10 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 10 file(s)

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionResumeChildSync.swift:112` `swift/preconditions` — The catch branch handles an unexpected encoding failure of `SAH.RestoreFailure`, and it only logs. It has no `assertionFailure`, so a debug build does not stop at the surprise and the author does not see it. Add `assertionFailure("The restore failure of a child did not encode: \(error)")` before the existing `logger.error` call in the catch block. Keep the log, so release builds still record it and the update goes out without a reason.
- [x] `Sources/FoundationModelsACPAgent/Agent/SessionResumeChildSync.swift:156` `reuse/reuse` — The new `announced(_:)` repeats the subagent lookup that `currentUpdate(of:)` already writes inline. Both find the first `subagents` entry whose `sessionId` matches. Two copies of the same lookup can drift apart. Call `announced(_:)` from `currentUpdate(of:)` for the `.subagent` case, so the lookup exists in one place. Or move the lookup into `announced(_:)` and have `currentUpdate` use it.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift:106` `reuse/reuse` — The new `Wire.ownState(of:)` repeats the test that the new `isOwnState(of:)` already makes. Both match a `state_update` on the child's own stream. The `Wire` version also restricts the match to updates after the response. Reuse the predicate. For example, `ownState(of:)` can filter `afterResponse` with a shared `isOwnState`-style test on the `Sent` update and session. This keeps the 'own state' definition in one place.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift:130` `reuse/reuse` — The new static helper `isAnnouncement(of:)` and the new `SessionUpdate.announces(_:)` extension do the same check. Each returns true for a `subagentUpdate` whose `sessionId` is the given child. The test file now has two copies of one predicate. Make `isAnnouncement(of:)` build its closure from `update.announces(child)`, or remove one of the two and use the other everywhere.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift:237` `reuse/reuse` — The new `resumeWithoutSync()` repeats the setup that `syncOfTheShutDownChain()` also writes inline. Both make a second `ScriptedPromptFixture`, then call `routedConnection.resumeSession` with `request(recording, replayFrom: nil)`. The same setup appears in two places, so a change to one can miss the other. Add one helper that makes the second fixture and resumes the recording with no replay. Both `resumeWithoutSync()` and `syncOfTheShutDownChain()` should call it, and `resumeChainWithoutTheChildAgent`'s setup can use it too.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift:255` `swift/concurrency` — The `Task` in `startWork` is unstructured and its handle is discarded. If the sync never opens the child's gate, the task waits forever and nothing cancels it. The doc comment gives the reason for the task, but the handle is still not stored or cancelled. Store the handle, for example `let work = Task { ... }`, and cancel it or await it in the test's teardown. Or run the call with `async let` in a structured scope. Keep the doc comment, since it explains why the call must run apart from the poll.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift:501` `swift/optionals` — A test uses `guard case .subagentUpdate(let sent)? = update else` and returns early. This is a `guard` in a test, and the early return skips the assertion that follows it. Unwrap with `try #require`, for example `let sent = try #require(update)` followed by a `guard`-free pattern match that binds the `.subagentUpdate` payload, or `#require` on the extracted value. Then keep `#expect(sent.capabilities == .unchanged)`.
- [x] `Tests/FoundationModelsACPAgentTests/ResumeNestedSessionsTests.swift:87` `reuse/reuse` — The new loop in `recordInterruptedChain` suspends every live session. The existing `quit(_:)` helper in the same file already does this loop, so the suspend logic now appears in two places. Extract the suspend loop into a helper, for example `suspendAll(of agent:)`, and call it from both `quit(_:)` and `recordInterruptedChain`. The interrupted recording does not close the fixture, so the helper must stay separate from the close step.
- [x] `Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift:110` `reuse/reuse` — The new reader task in `resume(replayFrom:)` is a near-copy of the reader task in `ResumeChildSyncTests.resume`. Both subscribe to all sessions, map each event with `WireTraceEvent(sequenced)`, and collect events until the response. The two copies can drift apart, for example in how they handle events that do not map. Move the subscribe-and-collect loop into one shared helper in the test support, with an optional stop test. Both suites should call it, so the wire reading is defined once.
- [x] `Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift:118` `swift/state-modeling` — The `switch` over `WireTraceEvent`, a domain enum, ends in `default: continue`. A newly added event case is silently skipped by the reader, so the compiler cannot flag it. Replace `default: continue` with explicit cases for the other `WireTraceEvent` cases, each one a `continue`. Then the compiler reports any new case that the reader must handle.

## Review Findings (2026-11-04 08:54)

> Scope: `review sha d4bc35f~1..8897e2d` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 16 not reviewed.

> 16 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 16 file(s)

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionResumeChildSync.swift:112` `completeness/public-output-contract` — The change adds an assertionFailure to the encode-error branch of announceFailure. Before this change the branch only logged the error and sent the announcement without a reason. In a debug build the new assertion stops the process on the same path the log line handles. The task asked for the error to be logged, not for a hard stop, so a previously recoverable path now fails hard in debug builds. Remove the assertionFailure and keep the logged error. If a debug trap is wanted, state the reason in the task. Add a test or a note that says what the encode failure should do.
- [x] `Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift:67` `reuse/reuse` — The new helper `announcement(in:)` repeats the logic of the `announcement` property on `SessionUpdate`. That property is in `ResumeChildSyncTests.swift` and is declared `fileprivate`, so this file cannot call it. The same mapping from a notification to a `SubagentUpdate` is now written in two places. A change to one copy can leave the other wrong. Move the `SessionUpdate.announcement` extension out of `ResumeChildSyncTests.swift` into `Tests/FoundationModelsACPAgentTestSupport/WireTraceReading.swift`, and make it non-private. Then `SubagentSessionsReplayTests` can call `notification.update.announcement` and the private helper can be removed. Use the same property in `ResumeChildSyncTests`.

## Blocker (2026-11-04)

True conflict between two rules. A person must correct a rule and restart the work. Do not resolve this conflict in code.

- The first finding of the review of 2026-11-04 08:38 (`swift/preconditions`, `SessionResumeChildSync.swift`) required an `assertionFailure` in the catch branch of `announceFailure`. That finding is fixed and checked.
- The first finding of the review of 2026-11-04 08:54 (`completeness/public-output-contract`, `SessionResumeChildSync.swift:112`) requires removal of the same `assertionFailure`.
- Both rules cannot be correct for the same line. If the implementer obeys one, the next review reports the other.
- The second finding of the review of 2026-11-04 08:54 (`SubagentSessionsReplayTests.swift:67`) does not conflict. It stays open for the implementer.

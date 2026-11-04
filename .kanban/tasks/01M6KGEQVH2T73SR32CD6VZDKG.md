---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6kmn89pmwxtft24jp4cwqkh
  text: |-
    DECISION (open point 4): the interrupted prompt of the root after a resume.
    Facts. The resume does not replay a state_update (isReplayedState is false for it). The state_update snapshot of the root comes from the ledger of the restored session. A new ledger is idle. Its idle has no stop reason and no error. The code comment of currentSnapshot says: a snapshot is not a new completion and not a new cancellation. So the root does not report a completed prompt after the resume. This holds with no change in the resume code.
    Decision 1. The root snapshot after the resume stays idle with no stop reason. The prompt is not completed, and it is not cancelled. A test pins it (theRootAfterAShutdownReportsNoCompletedPrompt).
    Decision 2. At the shutdown, the prompt of the root ends with a new stop (PromptStop.interrupted). The wire stop reason is the extension value _interrupted (the ACP _ extension rule, as _stalled and _truncated). Reason: cancelled is a final stop, and a cancelled prompt closes its tool calls as cancelled. The card rules say that an interrupted run is not final. The user decision of 2026-11-03 says runs are one-shot and only INTERRUPTED runs are restored. A prompt that ends as cancelled would show a finished run. The stop _interrupted shows an unfinished run. If a session/cancel reached the prompt before, the stop stays cancelled.
    Decision 3. The shutdown pauses only the calls with status in_progress. A pending call has not started, so it is not paused. A pending call has no final status, so the resume reads it as interrupted too.
    Decision 4. After the shutdown begins, a final status of a tool call goes nowhere in that session (InterruptedToolCalls). Reason: the stop of the agent runs lets a waiting tool call return. A test run showed the child agents call get completed after the pause. That would be a final status in the history. The call must stay paused.
    Spec check. ToolCallStatus.paused exists in the checkout (Unions3.generated.swift). SessionMergeEngine isTerminal returns false for .paused. session/close and session/delete are not changed: they still cancel (tests aUserCloseCancelsTheAgentsCallOfTheRoot and the existing close tests).
  timestamp: 2026-11-04T16:00:48.438488+00:00
- actor: claude-code
  id: 01m6kmngdemdczpxcfcg9fphtt
  text: |-
    ### implement — changed
    - evidence: full `swift test` (foreground, one run): 1772 tests, 194 suites, pass, 1 known issue (HarnessSmokeTests, intentional). No other issue. Filtered runs pass: OrderlyShutdownTests (7), ResumeChildSyncTests (24), InterruptedToolCallsTests (5 cases), ResumeNestedSessionsTests, SubagentSessionsReplayTests, SubagentCancelTests, ClosingOrderTests, RestoreFailureMetaTests. Only build messages: "missing creator for mutated node" (mlx bundle) and the old redundant #require warning in AgentTranscriptWiringTests.swift (not from this work).
    - production: tearDownSession on the isShutdown path no longer calls cancelAll or waitForPromptEnd. New `interruptOpenWork` pauses the in_progress tool calls of the session and of its children (`pauseOpenToolCalls`, status paused through the projector, so the history records them), and marks each open prompt interrupted. The prompt ends at the session close with stop `.interrupted` (wire `_interrupted`), and closingStatus for it is nil. `InterruptedToolCalls` drops a final tool call status after the shutdown began. The user close path is unchanged (`cancelOpenPrompts` holds the old code).
    - TDD: RED first for aShutdownPausesTheAgentsCallOfTheRoot and the three resume tests (aShutdownLeavesEachAgentsCallPausedInTheReplay, aShutdownRestoresTheChildrenAfterTheResume, theWireAfterAShutdownFollowsTheRulesOfTheValidator). The race (child agents call completed after the pause) showed in a combined run and gave InterruptedToolCallsTests. Pinning tests that pass at once: aUserCloseCancelsTheAgentsCallOfTheRoot and theRootAfterAShutdownReportsNoCompletedPrompt (they pin the kept behaviour and the decision).
    - earlier tests changed: ResumeChildSyncTests aChildWhoseCallIsFinalGetsNoSnapshotAfterTheResponse and aChildWhoseCallIsFinalSendsNoOwnStateAfterTheResponse used the real shutdown as the fixture of a final call. The shutdown now gives a paused call, so they use a new fixture `ResumeNestedSessionsTests.recordClosedChain` (a user session/close of the root, final `cancelled`). Assertions are the same; a new #require proves that the history of the resumed root holds the final status, so the tests are not vacuous. ResumeNestedSessionsTests: only the doc of recordShutDownChain and the new recordClosedChain. SubagentSessionsReplayTests and ClosingOrderTests: no change needed (they do not use the real shutdown). No assertion weakened, no test skipped.
    - files: Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift, Sources/FoundationModelsACPAgent/Agent/SessionShutdownPause.swift (new), Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift, Sources/FoundationModelsACPAgent/Agent/PromptState.swift, Sources/FoundationModelsACPAgent/Agent/SessionProjector.swift, Tests/FoundationModelsACPAgentTests/OrderlyShutdownTests.swift, Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift, Tests/FoundationModelsACPAgentTests/ResumeNestedSessionsTests.swift, Tests/FoundationModelsACPAgentTests/InterruptedToolCallsTests.swift (new)
    - not touched: SessionSetup.swift, ConfigOptions.swift, sibling packages, validators. Boxes ticked, description text unchanged.
    - next: /review. Task stays in doing.
  timestamp: 2026-11-04T16:00:56.750780+00:00
position_column: doing
position_ordinal: '8480'
title: Orderly shutdown pauses the open tool calls and does not cancel them
---
## What
An orderly shutdown (SIGTERM, `agent.shutdown()`) must not cancel the open root prompt. Today `tearDownSession` in `Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift` calls `entry.session.cancelAll()` and `waitForPromptEnd()` first, also when `isShutdown` is true. The root `agents` call then gets the final status `cancelled` in the history. After a resume, rule 1 of ^7wta3jt does not restore a child whose call is final, so an orderly shutdown restores no child. Only a hard kill restores an interrupted child.

Found by the implement step of ^7wta3jt (a `cancelled` tool_call_update for the root `agents` call was seen during `agent.shutdown()`).

## Decision source
Relayed by the peer session foundationmodelsacpagent-9b from its user, after it read Schema/acp-v2.unstable.json:
- `ToolCallStatus` has `paused`: the call has started, is not running now, and does not continue until something resumes it. It may return to `in_progress`. It is not final. `SessionMergeEngine` already treats `.paused` as not terminal, so validator rule 8 does not fire for a paused call.
- `session/close` (CloseSessionRequest): the agent MUST cancel ongoing work as if `session/cancel` was called, send the final updates and the idle `state_update` with stopReason `cancelled`, then respond. So `session/close` and `session/delete` KEEP cancelling. Do not change them.
- An orderly shutdown is not a `session/close` request. The spec says nothing about process shutdown.

## Do
Change `tearDownSession` for the `isShutdown` path only:
1. On shutdown, do not call `cancelAll()` on the open root prompt. Suspend the sessions (the agent runs are already suspended).
2. The open tool calls of the root and of each running child (the `agents` call at least) get a `tool_call_update` with status `paused`, not `cancelled`. The history then holds no final status for them. Check the translator for a way to send the update before the connection closes, and that the history records it.
3. On resume, a paused call is not final, so rule 1 of ^7wta3jt restores its child. When the child is re-driven, the call returns to `in_progress`.
4. Settle one open point on this card (ask the peer session if it is not clear): how the interrupted prompt of the root looks after a resume. The `state_update` snapshot after a resume must not report a completed prompt for the root.
5. Do not change a sibling package.

## Acceptance Criteria
- [x] After `agent.shutdown()` with an open root prompt, the history holds the `agents` call with status `paused`, and no `cancelled` status.
- [x] After a resume with replay, the interrupted child is restored, and the wire passes `SubagentWireTraceValidator`.
- [x] `session/close` and `session/delete` still cancel the open work with a final `cancelled` status.
- [x] The root does not report a completed prompt after the resume.

## Tests
- [x] A test with the REAL shutdown path: `agent.shutdown()`, then resume with replay. It checks that the call is `paused` in the history and that the child is restored.
- [x] A test that `session/close` still cancels.
- [x] Run `swift test` for the touched suites, then the full suite. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents
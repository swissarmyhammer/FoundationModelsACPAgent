---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rzxvn0q74d46tj6wtj0vz9
  text: |-
    Root cause found (2026-11-18, in this package, not in the Router): `EchoSessionBackend.transcriptEntries()` gave `[]` ("the echo keeps no transcript"). The Router records its journal from the transcript of the backend, so an echo turn recorded no `.prompt` and no `.response` entry. Thus (a) the journal had no turn, and the session directory refused each turn cut with `forkCutOutOfRange` ("The session has no such turn"); `.lastCompletedTurn` still worked, as the app saw; and (b) the Router sent no `entryRecorded(.response)`, so `ACPEventTranslator.closeMessage` never cleared the agent message id, and turn 2 streamed into the agent message of turn 1. A scripted backend records both entries, so the bug did not show with it.
    Fix: `EchoSessionBackend` keeps a transcript under a `Mutex`: one `.prompt` and one `.response` entry for each answer (respond and stream); `makeFork()` copies it, and `EchoLLMContainer.makeSession(transcript:)` restores it.
    Tests: `Tests/FoundationModelsACPAgentTests/SessionForkEchoTests.swift`, each for the echo model and a scripted model: `twoTurnsGiveTwoAgentMessages`, `aCutBeforeTurnTwoForksTurnOne`, `aCutAfterTheAnswerOfTurnOneForksTurnOne`. RED first with the echo model (one agent message; both cuts refused "no such turn"); the scripted cases passed. GREEN after the fix. Not committed (the coordinator commits). Push and the sha for TestudoApp are for the coordinator.
  timestamp: 2026-11-19T04:09:38.720610+00:00
- actor: claude-code
  id: 01m7s0068ttc28hw17j969wwg3
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Configuration/EchoModel.swift; Tests/FoundationModelsACPAgentTests/SessionForkEchoTests.swift (new).
    - test: `swift build --build-tests` Build complete!, 0 compiler warnings; full `timeout 1800 swift test --skip-build` (together with ^ccx24tw): 2435 tests in 255 suites pass, 1 known issue (pre-existing). SessionForkEchoTests: 3 tests x 2 models pass.
    - The cause is not in the Router. Not committed; push and the sha for TestudoApp (testudoapp-9a) are for the coordinator.
    - next: review.
  timestamp: 2026-11-19T04:10:55.130999+00:00
position_column: doing
position_ordinal: '8280'
title: 'D205 bug: Fork from Here after two echo turns says "no such turn", and turn 2 reuses the agent message id of turn 1'
---
Bug report from the TestudoApp session (2026-11-18). Found by TestudoApp IntegrationTests `SessionForkIntegrationTests.forkFromHereOnTurnTwo`, on ACPAgent 8b591b1a and Router de36cd24. The test is disabled in the app until this is fixed.

## Symptoms

- The test runs two turns with the echo model. The source is idle at the end.
- Each Fork from Here cut is refused with "The session has no such turn": the cut BEFORE the turn 2 user message, and the cut AFTER the turn 1 agent message.
- The answer of turn 2 has the SAME ACP message id as the answer of turn 1. Thus the client shows one agent message: "Plan step onePlan step two".
- Fork Session (last completed turn) and /btw work end to end.

## Guess of the app session (not verified)

`ACPEventTranslator.closeMessage` sets a new message id only when a recorded `.response` entry arrives. The echo turn may record no such entry. Then the agent message id does not change between turns, and the Router directory may see no completed turn.

## Work

1. Reproduce with a test of two turns (the echo model, the real Router directory in-process), then two Fork from Here cuts (`before` the turn 2 user message, `after` the turn 1 agent message).
2. Find the root cause. Check both: the message id of an agent message per turn (ACPEventTranslator), and the turn count of the cut map against the Router journal. Check whether the echo model records a `.response` entry, and what the Router counts for it.
3. If the cause is in the Router, write it on this card and tell the Router session (foundationmodelsrouter-f1).
4. Fix the cause in this package. Each turn's answer has its own message id. Both cuts give the expected fork (turn 1 only).

## Tests

- Two echo turns give two agent messages with different message ids.
- A cut `before` the turn 2 user message gives a fork with turn 1 only.
- A cut `after` the turn 1 agent message gives a fork with turn 1 only.
- The same with a scripted (non-echo) model.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d205 #fork #bug
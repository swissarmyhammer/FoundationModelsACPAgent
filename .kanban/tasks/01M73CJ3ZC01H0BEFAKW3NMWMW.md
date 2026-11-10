---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73fr03pe11amvxcg9hkwetg
  text: |-
    Research (implement step, worktree agent-acfb1dc7cdccf262d).
    - Note: the implement step moved this card to `doing` by mistake, and then moved it back to `todo` at ordinal 9080. The `started` time of the card stays set.
    - The only agent requests that name a session are the questions of `ElicitationRelay` (`elicitation/create` and `session/request_permission`). Both go out in `startWireRequest`, which reads the connection that `relayRequest` got from `outboundPath` before some awaits.
    - So there is a second race: a question can read the old connection before the take, and start its wire request after the take and after `withdrawOpenQuestions`. The decision must be made in the same actor step as the start of the wire request.
    - Plan: the relay gets a second closure that gives the hold of the tree (`ConnectionTable.route(forSession:)`). When that hold holds, the question becomes a withdrawn question, and the relay puts one send in the hold queue that asks it. Thus the ask goes in order with the held updates, after the snapshots. When the hold is discarded (a later take, or the close of the connection), the question stays withdrawn, and the next hot resume asks it again (`reaskWithdrawnQuestions`). The held ask takes the id out of the withdrawn set, so the re-ask after the release does not ask it a second time.
    - Test: the client side can record the wire arrival number of each agent request (`ClientSideConnection.currentRequestArrival`), so a test can merge the requests with the subscription events into one trace for `SubagentWireTraceValidator`.
  timestamp: 2026-11-10T19:42:46.390680+00:00
- actor: claude-code
  id: 01m73gkcc55eny6xynq5rhsw3d
  text: |-
    ### implement — changed
    - evidence: branch `par/w3nmwmw`, commit 422c6f4, worktree agent-acfb1dc7cdccf262d. Files: Sources/FoundationModelsACPAgent/Agent/ElicitationRelay.swift (`askOrHold`, `reaskWithdrawnQuestion`, closure `resumeHold`), SessionResumeHold.swift (`admit(_:)` -> `Admission`), SessionBuild.swift, SessionResumeHot.swift (doc), ARCHITECTURE.md (the hold also keeps the new questions), Tests/FoundationModelsACPAgentTestSupport/RecordingClient.swift (arrival number of each agent request), WireTraceReading.swift (`SequencedTraceEvent`, `readSequencedResumeTrace`, `WireTraceEvent.merged`), Tests/FoundationModelsACPAgentTests/HotResumeTests.swift (6 new test cases).
    - RED: `aQuestionOfTheChildInTheWindowWaitsForTheReplay` (elicitation, permission) and `theWireOfAHotResumeWithAQuestionInTheWindowFollowsTheRulesOfTheValidator` (elicitation, permission) failed on their expectations. `theAnswerToAQuestionOfTheWindowReachesTheChild` and `aQuestionOfTheWindowIsAskedOnceOnTheNewOwner` hit the 2 minute time limit, because the client model got the question before it knew the child. GREEN: all 6 pass in about 2 s.
    - `swift test`: 1922 tests in 211 suites passed, 0 failures, 1 known issue that was there before. No compiler warning (the one build line is the build-system notice "missing creator for mutated node").
    - Note: the window wait polls a condition with `pollUntil` (the same pattern as `waitUntilRecorded`): the condition is "the new connection got the request, or the relay keeps the question" (`ElicitationRelay.withdrawnQuestionCount`). No clock decides the order.
    - Gap with no test: a question whose hold is discarded (a later take, or the close of the connection) stays withdrawn for the next hot resume. No test covers this path.
    - next: review.
  timestamp: 2026-11-10T19:57:43.685073+00:00
- actor: claude-code
  id: 01m73gv9tgbr53k9b7e4t2n7rm
  text: |-
    ### review — clean
    - evidence: review sha 422c6f4~1..422c6f4 — 0 findings (0 confirmed, 3 refuted, 7 files reviewed; ARCHITECTURE.md has no validator).
    - next: none. The task is in done.
  timestamp: 2026-11-10T20:02:03.216816+00:00
- actor: claude-code
  id: 01m73hgd6pqf931aztsqxjcxvp
  text: |-
    ### review — findings
    - evidence: review sha 7d51b14..4972dea (in the main tree; this review replaces the earlier worktree review). 3 findings (3 confirmed, 2 refuted) — Sources/FoundationModelsACPAgent/Agent/ElicitationRelay.swift:839, Tests/FoundationModelsACPAgentTests/HotResumeTests.swift:369, Tests/FoundationModelsACPAgentTests/HotResumeTests.swift:654. ARCHITECTURE.md was not reviewed (no validator matches it).
    - next: implement the 3 findings in the "Review Findings (2026-11-10 14:09)" section, then review again.
  timestamp: 2026-11-10T20:13:34.806687+00:00
- actor: claude-code
  id: 01m73hyd5gwkdagy8tma7btaj4
  text: |-
    Work on the 3 findings of "Review Findings (2026-11-10 14:09)" (main tree, not committed).
    - Finding 1: new helper `ElicitationRelay.unsupportedModeDecline(of:elicitationId:on:)`. It does the capability gate, writes the notice record (new `logDecline(elicitationId:mode:reason:)`, which `decline(...)` also calls now) with the reason `unsupportedMode`, and gives the decline response. `relayRequest` and `reaskWithdrawnQuestion` both call it. Each caller only delivers the response (Router `respond` on the first ask, `deliver(_:toPending:)` on the re-ask).
    - RED for finding 1: new test `HotResumeTests.aPendingQuestionThatTheNewOwnerCannotAnswerWritesOneDeclineRecord` (the second connection advertises `url` mode only, the pending `form` question is re-asked, and the test counts the decline records). It failed before the change (0 records) and passes after.
    - Finding 2: one helper `resumeAcrossTheWindow(of:waitingInTheWindow:)` holds the wire, the holder, the subscription, settledBy, the timeout and the hold sequence. It takes the in-window wait as a parameter and returns `WindowWire<Observed>`. `resumeTraceAcrossTheWindow` and `resumeAcrossAQuestionWindow` give only their wait and their return value. Note: both now resume with `second.client.resumeSession` (the model). Before, the window path used `second.connection.resumeSession`. The window tests pass with the change.
    - Finding 3: `aQuestionOfTheWindowIsAskedOnceOnTheNewOwner` and `theAnswerToAQuestionOfTheWindowReachesTheChild` take `QuestionKind.allCases`. `QuestionKind.method` gives `ElicitationWireRecorder.createMethod` or `permissionMethod`, and the once test counts the `agentRequests` of that method. `answerQuestion(_:of:)` can answer both kinds now: it accepts an elicitation, and it selects the allow option of a permission request (`ScriptedPermission.allowOptionId`). No limit to state. The permission cases passed on the first run, because the production code already holds permission questions; they add cover, not a RED.

    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPAgent/Agent/ElicitationRelay.swift, Tests/FoundationModelsACPAgentTests/HotResumeTests.swift. `swift test --filter HotResumeTests`: 21 tests (25 cases) passed. Full `swift test`: 1938 tests in 212 suites passed, 0 failures, 1 known issue that was there before (HarnessSmokeTests). No compiler warning (the one build line is the build-system notice "missing creator for mutated node").
    - next: review.
  timestamp: 2026-11-10T20:21:13.520854+00:00
position_column: doing
position_ordinal: '80'
title: 'Hot resume: a new question of a child in the window between the take and the response goes to the new connection before the replay'
---
## What
Found during ^4273b5t (2026-11-10). The fix of ^4273b5t holds each live `session/update` of the tree from the take of a hot resume until after the response (`SessionResumeHold`). Requests of the agent do not go through that hold. The relay of a session reads its path when it asks (`ElicitationRelay` `outboundPath`, `ConnectionTable.path(forSession:)`). So a NEW question (elicitation or permission) that a child asks after the take and before the response goes to the new connection at once:
- before the replay announces the child: rule `announceBeforeUse` ("<method> names <child> before it is announced");
- between the resume request and the response: rule `noReplayedRequests`.
The open questions at the take are not affected: `withdrawOpenQuestions` and `reaskWithdrawnQuestions` handle them, and the re-ask comes after the release of the hold.

## Work
1. Reproduce with a deterministic test like `HotResumeTests.resumeTraceAcrossTheWindow` (the `FrameHoldingTransport` keeps the first replay frame): the child asks a question in the window.
2. Fix: a question that starts while the hold of its tree holds waits, and goes out after the release (for example the relay treats it as withdrawn and the hot sync asks it after the release).

## Acceptance Criteria
- [ ] No agent request names a child of the tree before the response of a hot resume, and before the snapshot of that child.

## Tests
- [ ] The deterministic test above (fails before, passes after).
- [ ] `swift test` passes with no warnings. #step1

## Review Findings (2026-11-10 14:09)

> Scope: `review sha 7d51b14..4972dea` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 1 not reviewed.

> 1 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Agent/ElicitationRelay.swift:839` `reuse/reuse` — The capability gate of reaskWithdrawnQuestion repeats the gate of the first-ask path. The first-ask path calls decline(...) with reason .unsupportedMode, which also writes the log record. The new code builds the decline response directly and delivers it, so the re-ask path skips the log. The duplicate has already drifted from the original. Move the gate and its decline into one helper, for example a function that takes the mode and the path, and call it from both the first-ask path and reaskWithdrawnQuestion. Then the decline, its log, and its reason stay in one place.
- [x] `Tests/FoundationModelsACPAgentTests/HotResumeTests.swift:369` `reuse/reuse` — resumeAcrossAQuestionWindow repeats the body of resumeTraceAcrossTheWindow: the same wire setup, holder, second connection, subscription, settledBy closure, timeout, and hold sequence. Only the question wait and the returned value differ. Two copies of the window-resume choreography must now be kept in step by hand. Extend resumeTraceAcrossTheWindow so that it takes the in-window wait as a parameter, or extract the shared wire, holder, and subscription setup into one helper. Then resumeAcrossAQuestionWindow calls that helper and adds only its question wait and its return value.
- [x] `Tests/FoundationModelsACPAgentTests/HotResumeTests.swift:654` `completeness/invariant-propagation` — The 'asked once on the new owner' check counts only `creates`, which are elicitation requests. It does not count permission requests. The test is not parameterized over `QuestionKind`, so a permission question that is asked twice on the new owner passes this test. The same gap applies to the answer test at line 630, which also uses only `.elicitation`. The permission path of the window hold is therefore not checked for the single-ask rule or for the answer delivery. Parameterize `aQuestionOfTheWindowIsAskedOnceOnTheNewOwner` and `theAnswerToAQuestionOfTheWindowReachesTheChild` over `QuestionKind.allCases`. Count the requests of the matching method in `agentRequests` (for example by `RecordingClient.permissionMethod` and `createMethod`), not only `creates`. If the answer helper cannot answer a permission question, state that limit in the test doc instead.

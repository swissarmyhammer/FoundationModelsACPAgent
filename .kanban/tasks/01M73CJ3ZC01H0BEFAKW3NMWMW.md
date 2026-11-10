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
position_column: todo
position_ordinal: '9080'
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
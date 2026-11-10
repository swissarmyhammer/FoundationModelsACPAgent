---
assignees:
- claude-code
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
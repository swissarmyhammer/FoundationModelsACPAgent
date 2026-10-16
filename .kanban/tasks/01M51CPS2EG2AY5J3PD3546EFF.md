---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Bad test: sessionCancelDuringAPendingElicitationDeliversCancelBeforeIdle has no fixed point for the end record'
---
CI 38843303710 (8412749, Extras 6cfd13c) failed in `ElicitationRelayTests.sessionCancelDuringAPendingElicitationDeliversCancelBeforeIdle`: `ends.count == 1` gave 0, and the end reason was nil. The test passed in the local full run on the same commit, and in CI 38831958055 (4359b57, Extras e65287a).

What the log shows: no relay record with `elicitation.end_reason` at the time the test reads the records. The CI log has no agent log records, so the cause is not proven.

Facts:
- The URL question makes its run wait only for the user, so Router already sent `workEnded` (Router doc of `workEnded`).
- `session/cancel` sends `cancelAll()`. Router sends the terminal of the prompt mail first, and then `elicitationEnded` (before `signalDone`). Thus the prompt can end, and the idle can go out, before the relay gets the end.
- The test reads the records after `waitForIdle` and `fixture.close()`. `closeSession` drains the projector (`projector.stop(after:)`), but `fixture.close()` swallows a failed `closeSession` (`try?`), and then the connection close tears the session down on its own task.

Possible causes:
- (a) The race above, with a `closeSession` that did not finish the drain.
- (b) Router sent no `elicitationEnded` for the question, and the drain at the end of the feed released the round trip with `cancel` and no reason. This would be a defect.

Proposed fix of the test: wait for the end record as a fixed point (`context.wait` on a record with `elicitation.end_reason`) before `fixture.close()`, as the ^t2sen06 tests do. Then (a) cannot happen. A hang then shows (b). Do not change the test before the step lead decides. #bad-test #elicitation-phase-3

## Findings (2026-10-16)

- Cause found: CI resolved Router main 2f78fda (^pjycptw: the run plane posts the question ends, and Router's own end logic is gone). My local run used Router 61d5711. On Router 2f78fda with Extras 6cfd13c, the test failed in one local run of only this test, and again in the full run.
- The Router events after the cancel: `cancelled(mail)`, `cancelled(mail)`, `answerFailed(.cancelled)`, `signalDone`, `runSettled(runCode, cancelled)`, `workEnded`, `runProgress(CancellationError())`. No `elicitationEnded` comes, before `signalDone` or later. The relay drain then gives `cancel` with a warning. Thus cause (b): a Router defect. The Router session (foundationmodelsrouter-fa) took it as a #defect card on its board.
- Test changes (step lead decision):
  - `ScriptedPromptFixture.close()` records an issue when `session/close` fails, and does not swallow the error. A `session/close` that succeeded returns after the projector sent each event, so a read after `close()` is a fixed point.
  - The test reads the records after `fixture.close()`. Its doc says why. I did not add a wait for the end record: on Router 2f78fda that wait would hang, and a fail is better than a hang.
- This test stays red until the Router fix lands. No other test had a failed `session/close` in the full run.
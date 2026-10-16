---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'Defect: a run cancel of a foreground runCode ends the prompt as cancelled'
---
Found in task ^az53ay4 (test `aRunCancelAfterAURLAcceptSendsOneCompletion`).

Observed event order on the prompt mail, after `RunPlane.cancel(completionToken:)` of the run of the foreground `runCode` call:
1. `elicitationEnded` (cancel, "run cancelled"), then `runSettled` with outcome `cancelled` and detail `CancellationError()`.
2. `toolStatus(scripted-call-1, failed)`, then `submissionEnded` (finish reason `completed`).
3. `answerFailed(reason: .error("CancellationError()"))`.

The agent then reads the typed error through `awaitAnswer`. `PromptExecution.classify` sees `CancellationError` (`isAbort`) and ends the prompt with `idle(cancelled)`.

Why it is a defect: the client did not cancel the prompt. The README cancel rule says "you can only stop what you stop". A cancel of one run must stop only that run. Router itself says "A cancel of one mail never stops a chain". The expected result: the model gets a cancelled tool result, and the prompt ends `end_turn`.

Where the fix goes (a decision for the step lead):
- (a) Router or Multitool: the foreground wait of a cancelled run returns a cancelled tool result to the model, and does not throw `CancellationError` into the chain. This is a follow-up card on that project.
- (b) The agent: classify `answerFailed(.error)` that carries `CancellationError` as a failure, not as `cancelled`. This only changes the label, and the chain still fails.

Test: a fixed-order test that cancels the run of a foreground `runCode` and expects `end_turn`. It must fail on the code of today. #elicitation-phase-3 #defect
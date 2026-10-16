---
assignees:
- claude-code
position_column: done
position_ordinal: ffe280
title: 'Defect: a pause of mail delivery is not visible to the client, and the headless run reports done'
---
Found by the Router review of mailOnlyAnswerLimit. Do not start before the step lead says so.

Problem:
- When Router pauses mail delivery (SessionEvent.mailDeliveryPaused), ACPEventTranslator (ACPEventTranslator.swift:382-386) sends nothing on the wire. The client sees idle with no notice.
- The headless `acp-agent run` stops at the first idle after its own echo and reports done. Router still holds the paused mail, so the held results are lost.

Work:
- Make the pause visible to the client: an agent message, or a `_`-prefixed state or meta field. Send the design to the step lead first.
- The headless run must not report done while Router holds mail. It reports the pause and ends with a clear failure (an error exit code and a message on stderr).

Tests: fixed-order tests that fail on the old code: the pause reaches the client; the headless run ends with the failure and not with done when the delivery is paused. #defect #elicitation-phase-3

Done (design (1)-(3) accepted by the step lead):
- [x] `MailDeliveryPauseReport`: one `_mail_delivery_paused` update (limit, heldCount, heldMail [{tool, op, completionToken}], message) through the history sink, before the `idle`. No update for the lift.
- [x] `RoutedACPAgent.mailOnlyAnswerLimit` goes to `SessionConfiguration` in session/new and in the slot switch. `useMailOnlyAnswerLimit(_:)` is for tests only.
- [x] `acp-agent run`: `PromptEndTracker` keeps the last pause between the own echo and the ending idle. `AgentExitCode.mailDeliveryPaused = 6` wins over the stop reason. `HeldMailNotice.standardErrorLine` goes to stderr.
- [x] README: one design-decision bullet with the payload.
- [x] Tests: `MailDeliveryPauseTests` (the pause before the idle and in the history; the next prompt carries the held mail), `MailDeliveryPauseExitTests`, three `PromptEndTrackerTests`, `ExitCodeTests` row 6. With the translator arm and the exit rule removed, the wire tests and the exit tests fail.
- The subprocess path of `acp-agent run` has no own test (step lead decision: no flag and no environment knob). Why: the test seam `useMailOnlyAnswerLimit(_:)` reaches only the in-process agent, and the subprocess has no way to set the limit to `0`. Also, an in-process end-to-end test has no fixed point: the test cannot see the session id, so it cannot know that the own prompt ended before it releases the pipe. The `PromptEndTracker`, exit-code, stderr and wire tests together cover the path.
- Follow-up cards for ACPClient and AgentViewKit: the step lead adds them.
---
assignees:
- claude-code
position_column: done
position_ordinal: ffd780
title: Move to Router 77b2da68 and Extras 278e9cb; add the three new SessionEvent cases with no behavior change
---
Step lead request (swissarmyhammer-96).

Router 77b2da68 adds three public SessionEvent cases:
- .workStarted and .workEnded: no payload, origin .system, only on streamSessionEvents(). They alternate, workStarted first. None after close() starts. A run that waits only for the user is not work.
- .elicitationEnded(ElicitationEnd): elicitationId of elicitationRequested; response is .cancel(reason: RunPlane.runCancelledReason). Origin .mail([id]) for a run cancel, .signal(id) for cancelAll(), .system for close.
Also: after cancelAll() or close() ends a question, respond(elicitationId:response:) gives .noPendingElicitation.

Work:
- Move the pins to Router 77b2da68 and Extras 278e9cb (root and IntegrationTests, Examples if they pin).
- Add the three cases to ACPEventTranslator and to each other exhaustive switch. No behavior change: they send nothing to the client. Keep the switches exhaustive (no default).
- If a test breaks from the respond(elicitationId:) change, fix the test and name it.

Check: build, one full root run, IntegrationTests build. Commit, push when green, report the head and CI.

Not in this task: close the client request on elicitationEnded (^crjmk34) and running/idle from workStarted/workEnded. #mail-new-events
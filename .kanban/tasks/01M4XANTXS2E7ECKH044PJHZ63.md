---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xb6xc86pb76pp3dg1ey44m
  text: 'Decision from T0 (G1, step lead): T5 does no code. awaitIdle() is not in order with streamSessionEvents(), and a run that waits only for the user keeps the session busy. T5 records what Router must add (elicitation-plan tasks 9 and 10) and reports it.'
  timestamp: 2026-10-14T13:56:41.992172+00:00
- actor: claude-code
  id: 01m4xht9p4et88yhxag4sp08cp
  text: |-
    T5 result (decision G1): no code. The current public Router API (6cb38629) cannot give running and idle from Router work with no clock and no poll:
    - SessionEvent has no event for a change of the work of the session. awaitIdle() is event driven, but it is not in order with streamSessionEvents(): an idle from it can go to the client before the last buffered events of the answer.
    - awaitIdle() counts a run that waits only for the user (an open elicitation) as work, so a session with an open question never becomes idle.

    What Router must add (for elicitation-plan phase 1, not step 4):
    1. Router task 10: two session events on the output stream, in order with the other outputs, with the origin .system: one when the session gets work while it had none, and one when the session has no work any more (the three rules of awaitIdle(): no open background run, no pump work that runs or waits, no queued run mail that can start an answer). Each change sends one event, so a consumer needs no clock and no poll.
    2. Router task 9: a run that waits only for the user (it waits in RunPlane.awaitAnswer for an elicitation) does not count as work for isIdle and for these events. The other readers of openRuns do not change (hasPendingOperation still counts the run). This needs Extras task 15 (the link of each open question to its run token).

    Then ACPAgent (elicitation-plan task 2): SessionStateLedger sends running and idle from these events, not from the count of open prompts; awaitingUser and requires_action go away; the stop reason of the idle is the stop reason of the last prompt that ended.

    Today (step 4) ACPAgent sends running when the first prompt starts and idle when the last open prompt ends (SessionStateLedger), and no state update while no prompt is open (decision Q2).

    Per the family rule, I do not write a card on the Router board without a discussion: proposal sent to the step lead.
  timestamp: 2026-10-14T15:52:08.644893+00:00
depends_on:
- 01M4XANNYAHB1NCACW4B6HR5R3
position_column: done
position_ordinal: ffd080
title: 'T5: Running and idle from Router work (only with no clock or poll)'
---
Step 4 of the mail work, part T5. Do this task after T4. Refer to elicitation-plan.md tasks 2 and 10.

Work:
- Make the running and idle states come from Router work (elicitation-plan task 2). Do this only if the current public Router API gives this information with no clock and no poll.
- If the current public Router API does not give it, do not do this work. Record what Router must add (elicitation-plan task 10) and report it to the step lead. Do not change Router (a change in a family package needs a task on that project, discussed first).

The rules of T0 (STE, commit and report after each task, one full test run, no .timeLimit/sleep/poll/retry, ask before a decision that is not in the plan) apply. #mail-step-4
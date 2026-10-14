---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xb6xc86pb76pp3dg1ey44m
  text: 'Decision from T0 (G1, step lead): T5 does no code. awaitIdle() is not in order with streamSessionEvents(), and a run that waits only for the user keeps the session busy. T5 records what Router must add (elicitation-plan tasks 9 and 10) and reports it.'
  timestamp: 2026-10-14T13:56:41.992172+00:00
depends_on:
- 01M4XANNYAHB1NCACW4B6HR5R3
position_column: todo
position_ordinal: '8580'
title: 'T5: Running and idle from Router work (only with no clock or poll)'
---
Step 4 of the mail work, part T5. Do this task after T4. Refer to elicitation-plan.md tasks 2 and 10.

Work:
- Make the running and idle states come from Router work (elicitation-plan task 2). Do this only if the current public Router API gives this information with no clock and no poll.
- If the current public Router API does not give it, do not do this work. Record what Router must add (elicitation-plan task 10) and report it to the step lead. Do not change Router (a change in a family package needs a task on that project, discussed first).

The rules of T0 (STE, commit and report after each task, one full test run, no .timeLimit/sleep/poll/retry, ask before a decision that is not in the plan) apply. #mail-step-4
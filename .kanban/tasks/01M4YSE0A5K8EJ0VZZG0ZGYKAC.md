---
assignees:
- claude-code
position_column: done
position_ordinal: ffdb80
title: 'E2: Running and idle from Router work (elicitation-plan task 2)'
---
Step lead plan, part 2 of the new events. Do after E1. Send a short design to the step lead first, and write no code before the answer.

SessionStateLedger takes running from .workStarted and idle from .workEnded, also with no prompt open (this replaces the Q2 rule of step 4). Remove awaitingUser and requires_action (elicitation-plan section 8: the agent never sends requires_action; a run that waits only for the user is no work in Router now).

The design tells: the stop reason of an idle (and which one when only background work ran); how session/cancel still ends with idle and stop reason cancelled; how the headless CLI rule (the first idle after the echo of its own messageId) still finds the end of its prompt; which tests change.

Fixed-order tests: background work with no prompt open gives running then idle; an open question does not keep the session running. The tests fail on the old code.

Rules: one full run, no clock, sample before a stop, own pids only, commit after the task, report, push when the step lead accepts. #elicitation-phase-1
---
assignees:
- claude-code
position_column: done
position_ordinal: ffd880
title: 'E1: Close the client question on elicitationEnded (gap ^crjmk34)'
---
Step lead plan, part 2 of the new events. Do E1 before E2. Send a short design to the step lead first, and write no code before the answer.

When the projector reads .elicitationEnded(end), the relay ends its open client request for end.elicitationId with the ACP way to end an elicitation/create request, with the response and its reason. Router sends elicitationEnded for a run cancel, for cancelAll() and for close (before the feeds finish). The design tells if the G4 path (the relay cancels its own requests on cancelAll and close) can go, or why it must stay.

Fixed-order test: a run cancel while a question is open; the client request ends with the reason "run cancelled"; an answered question gets no end. The test fails on the old code.

Rules: one full run, no clock, sample before a stop, own pids only, commit after the task, report, push when the step lead accepts. #elicitation-phase-1
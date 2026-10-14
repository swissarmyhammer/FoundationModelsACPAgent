---
assignees:
- claude-code
depends_on:
- 01M4XANTXS2E7ECKH044PJHZ63
position_column: todo
position_ordinal: '8680'
title: 'T6: Remove the .timeLimit traits and each sleep, clock wait and poll in the tests'
---
Step 4 of the mail work, part T6. Do this task after T5.

Work:
- Remove the 298 .timeLimit traits in Tests.
- Remove each sleep, clock wait and poll in Tests, IntegrationTests and EvaluationTests.
- Replace each one with a wait on an event, a gate or a fixed order.
- Do not delete a test without a decision from the step lead.

The rules of T0 (STE, commit and report after each task, one full test run, no .timeLimit/sleep/poll/retry, ask before a decision that is not in the plan) apply. #mail-step-4 #tests
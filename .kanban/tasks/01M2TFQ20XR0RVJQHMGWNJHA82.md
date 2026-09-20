---
assignees:
- claude-code
position_column: done
position_ordinal: e080
title: The bench log must keep the error output, and the session/new timeout must name its step
---
Two faults of the bench made the failure of 2026-09-18 hard to read:
- The README commands use `| tee`, which keeps standard output only. An interrupt or a Python traceback thus never reaches `run.log`. Change each README command to `2>&1 | tee`.
- The line `the agent said nothing for 600 seconds` does not say that the wait was for `session/new`, and not for the turn. The message must name the method that got no answer.

Acceptance: the bench unit tests pass, and the timeout message names `session/new`. #bench
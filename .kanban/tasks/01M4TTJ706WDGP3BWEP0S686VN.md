---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'swebench scan: read the commandID of a "did not finish" notice as the id of a test run'
---
## Why

In `.claude/skills/swebench/scripts/scan.py`, `TOKEN_RE` finds only `completionToken": "<ULID>"`. The "did not finish" text of a snippet (PENDING_INNER, for example django__django-13964 of the run pending-inner-1012) names the command as `commandID "<ULID>"`. Thus a later `getLines` read of that command is not a test result in the "test result before and after the last edit" check. Found during ^9c4j9ck.

## Work

1. Find the command id of a "did not finish" notice of a test run, and add it to the test ids of the instance.
2. Add a test_scan.py case: a PENDING_INNER result of a test run, then a getLines read of its commandID with a summary.

#bench
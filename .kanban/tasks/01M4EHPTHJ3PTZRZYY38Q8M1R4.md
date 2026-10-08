---
assignees:
- claude-code
depends_on:
- 01M4E2AGVS1PG8A0NN0EXKKYYR
position_column: todo
position_ordinal: '8480'
title: 'bench scan: report repeated tool results, and the test result before and after the last edit'
---
## Problem

The swebench scan (`.claude/skills/swebench/scripts/scan.py`) reports only calls that fail. The run code-context-1008 (`bench/preds.code-context-1008.transcripts`) shows two loops that the scan does not report:

1. **Repeated results.** In django__django-14667, after one `use skill explore`, the model made 18 `list skill` calls in a loop (filters detected → lsp → map → code → explore, 3 times). Each call succeeded, so the scan reported nothing. The `getLines` polling loop of django__django-13964 is the same kind of loop.
2. **No change in the test result.** In each of the 4 unresolved instances, the test result that the model saw was the same before and after its edit. For example, in django__django-14155 the result was `Ran 1 test in 0.000s FAILED (errors=1)`, which is a test that did not load.

## Change

1. For each instance, count the tool calls whose result is the same as an earlier result in the same instance. Report the count, and the tool and the arguments of the largest group. Report an instance when the count is more than a threshold. Put the threshold in one named constant.
2. For each instance, give one line: the last test result before the last edit, and the first test result after it. Mark the instance when the two results are the same. Find a test run by the command text (for example `runtests.py`, `pytest`, `manage.py test`). Use the summary line (`Ran N tests`, `OK`, `FAILED (...)`).
3. Add both items to the ranked problem list of the swebench skill (`.claude/skills/swebench/SKILL.md`), if that list names the problem kinds.

## Tests

In `test_scan.py`, with small transcript fixtures:
- 18 calls of the same tool with the same result: the scan reports the instance and the count.
- A result that repeats less often than the threshold: the scan reports nothing.
- A test run before the last edit and a test run after it with the same summary: the scan marks the instance.
- Different summaries: the scan does not mark the instance.

## Source

The session foundationmodelsacpagent-19 found these gaps on 2026-10-08.

#bench
---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'swebench scan: find a repeated test run when the command text differs'
---
## Why

The review of ^nwy1gcf (2026-10-12) found a duplicate test run that the scan and two manual checks missed. In run pending-inner-1012, django__django-13964 seq 1017 ran the full test suite into a log file and seq 1032 ran the full suite again, because a pending inner result hid the output. The two commands have different text (a log redirect, a different module list), and the checks compared only identical `command:` text. So "0 duplicates caused by a pending result" was reported, and it was wrong.

## Work

In `.claude/skills/swebench/scripts/scan.py`:

1. Normalize each test command before the compare: the test runner and its module or test arguments only (drop redirects such as `> file 2>&1`, pipes such as `| tail -N`, `cd ... &&` prefixes, and `timeout` values).
2. Report a repeat when the same normalized test run happens again with no edit (files.edit / write / patch, or a git stash / checkout) between the two runs.
3. For each repeat, say whether the earlier run's result was pending or incomplete when the model saw it (the snippet result was a pending object, or the output was missing or empty), so that a repeat caused by a pending result is a PROBLEMS item with its seq numbers.
4. Also find a command that a snippet builds from a variable when the variable is a string literal in the same snippet.

Do not edit the harness (`bench/*.py`).

## Acceptance criteria

- On bench/preds.pending-inner-1012.transcripts, the scan reports django__django-13964 seq 1017 -> 1032 as a repeat that a pending result caused.
- On the same run, the scan does not report 13447 seq 286 -> 294 (an edit between) or 14382 seq 1465 -> 1473 (the first result was inline) as a pending-caused repeat.
- The scan output for other runs does not lose any item that it reports now.

## Tests

- Run the scan on pending-inner-1012, noop-stop-1012 and no-otel-1011, and compare the PROBLEMS part with the cases above (no-otel-1011 13447 seq 428-432 and noop-stop-1012 13447 seq 298-302 are pending-caused repeats too). #bench
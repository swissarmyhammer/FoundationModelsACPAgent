---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4er6rctrhayrp7es0p56kar
  text: The fix for this task is in commit b8adff1 (task ^8q8m1r4). The test step changed `json.load(open(...))` in `scan_score` to a `with` block, and added the test `TheScoreReportIsClosedAfterTheRead`. The suites pass with `-W error`. Only a review of b8adff1 for this task is left.
  timestamp: 2026-10-08T21:55:11.898572+00:00
- actor: claude-code
  id: 01m4erqp4hyfvs9c9zk03e64kv
  text: |-
    ### review — clean
    - evidence: `review sha b8adff1~1..b8adff1`. Counts: 0 findings, 0 confirmed, 0 refuted. 8 validator runs, 0 failed. The engine reviewed 2 files (`.claude/skills/swebench/scripts/scan.py`, `.claude/skills/swebench/scripts/test_scan.py`). The ignore rule `.reviewignore` removed 2 `.kanban/` files. The task had no prior `## Review Findings` section.
    - next: none. The task moves to done.
  timestamp: 2026-10-08T22:04:26.641243+00:00
position_column: done
position_ordinal: ffac80
title: 'swebench scan: scan_score leaves the score report file open (ResourceWarning)'
---
## Problem

`scan.py` in `.claude/skills/swebench/scripts` reads the score report with `json.load(open(reps[-1]))` in `scan_score`. The file stays open. With `python3 -W error .claude/skills/swebench/scripts/scan.py --name code-context-1008 --timeout 5400`, Python writes `ResourceWarning: unclosed file <... preds.code-context-1008.jsonl.score.score_20261008_141909.json ...>` with a traceback at the start of the output. The scan continues and exits 0.

## Change

Open the file in a `with` block (or use `Path.read_text`), so that the scan closes it. Look for the same `json.load(open(...))` pattern in the other functions of `scan.py`, and correct each one.

## Tests

In `test_scan.py`: write a small score report in the temporary bench dir, run `scan_score` with warnings set to error, and assert that no `ResourceWarning` occurs.

## Source

Found on 2026-10-08 during the fix of the review findings of ^8q8m1r4. That change did not touch `scan_score`.

#bench
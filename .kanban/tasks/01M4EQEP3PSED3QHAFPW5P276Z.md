---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
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
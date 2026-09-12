---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2b54x5k01bqrc9hav27hwk5
  text: |-
    Picked up. Research of the code that reads the report:

    - `score_report` in `bench/swebench_report.py` builds `errored_ids = list(errored)` and puts that same list at both `errored` and `errored_ids`.
    - NOTHING in the repository reads `report["errored"]`. `bench/swebench_score.py` reads `report["submitted"]`, `report["evaluated"]`, `report["resolved"]`, `report["unresolved"]`, `report["resolved_pct_of_evaluated"]`, `report["resolved_pct_of_submitted"]` and `report["run_id"]`. Its console table uses its own local `errored` list, and not the report.
    - So the change breaks no code in this repository. It changes only a file that a person can hold from an older run. `bench/README.md` must say so.

    Two places in `bench/README.md` speak of the report:

    - "Each score run writes `preds.jsonl.score.<run id>.json` beside the predictions, with the resolved, unresolved and errored ids."
    - The JSON quote of the run of 2026-09-11: `"submitted": 16, "evaluated": 0, "resolved": 0, "errored": [ ... all 16 ... ]`. That quote shows the OLD shape, so it needs a note.
  timestamp: 2026-09-12T15:53:01.363674+00:00
- actor: claude-code
  id: 01m2b5n1p4pjan7ryx0jy47wnz
  text: |-
    Implementation landed, with TDD.

    RED first: `test_it_counts_the_instances_that_did_not_run` and
    `test_each_group_gives_a_count` both failed with
    `['astropy__astropy-14182'] is not an instance of <class 'int'>`. GREEN after
    one line: `"errored": len(errored_ids)` in `score_report`.

    Is the change safe? YES. No step of the harness reads `report["errored"]`, so
    the change breaks no code. It changes only a file that a person can hold from
    an older run, and `bench/README.md` now says so, with the date 2026-09-12.

    Three files quoted the OLD shape of the report in their words, so each one now
    says which shape it shows:

    - `bench/README.md`, the quote of the run of 2026-09-11;
    - `bench/swebench_docker.py`, the module docstring;
    - `bench/test_swebench_docker.py`, the module docstring.

    I kept those quotes as they stand, because each is a record of a file that the
    run of that day truly wrote. A sentence beside each one says that the file is
    of the older shape, and that a run of today writes a count.

    `bench/README.md` also holds a new section, **What a score report holds**: a
    JSON example and a table of the thirteen names. It follows the pattern of
    **The record of a run** above it.

    Two checks of the linters that the validators use, on the four files I
    touched:

    - `ruff --select D,PLR2004,PLR0915`: 18 findings, every one of them on a line
      that was there before this change (D212, D401, D404), and none of them in
      the codes that the `missing-docs-python` rule names (D100 to D107). No
      finding on a line I wrote.
    - `vulture --min-confidence 60`: 7 findings, every one a `TestCase` class that
      was there before this change. My two tests are methods of a class that
      already stood, so they add no finding.
  timestamp: 2026-09-12T16:01:50.276699+00:00
- actor: claude-code
  id: 01m2b5n6434qykj004hj4f13zm
  text: |-
    ### implement — changed
    - evidence: 5 files — bench/swebench_report.py (`"errored": len(errored_ids)`, the fourth rule of the module docstring, the docstring of `score_report`), bench/test_swebench_report.py (`GROUPS`, `test_it_counts_the_instances_that_did_not_run`, `test_each_group_gives_a_count`, the fourth rule of the module docstring), bench/README.md (the section **What a score report holds**, and the note beside the quote of 2026-09-11), bench/swebench_docker.py and bench/test_swebench_docker.py (one sentence each, which says that the quote shows the older shape). `python3 -m unittest discover --start-directory bench --pattern 'test_*.py'`: 181 tests, 0 failures.
    - next: /review
  timestamp: 2026-09-12T16:01:54.819488+00:00
position_column: doing
position_ordinal: '80'
title: 'bench: the score report gives a list for `errored`, and a count for each other group'
---
## What I found

`bench/swebench_report.py` keeps the shape that `swebench_score.py` wrote
before. In that shape three groups give a count, and one gives a list:

```json
"submitted": 16, "evaluated": 0, "resolved": 0, "unresolved": 0,
"errored": ["astropy__astropy-14182", "..."],
"errored_ids": ["astropy__astropy-14182", "..."]
```

`errored` holds the same list as `errored_ids`. A reader who takes
`report["errored"]` for a count, as `report["unresolved"]` is a count, gets
a list.

## The work

1. Make `errored` the count of the instances that did not run, and keep
   `errored_ids` for the ids.
2. Say in `bench/README.md` that a report of an older run holds a list there.
3. Add the test to `bench/test_swebench_report.py`.

This changes the shape of a file that a person can hold from an older run,
so it is not part of the task that found it (`^j8ketc0`).

## When it is complete

- Each of the four groups gives a count, and the ids stand in the `_ids`
  names alone. #bench
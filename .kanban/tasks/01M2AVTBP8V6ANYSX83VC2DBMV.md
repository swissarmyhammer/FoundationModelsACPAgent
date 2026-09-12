---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
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
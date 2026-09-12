---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'bench: keep the patch when the watchdog stops an instance'
---
## The problem

`bench/swebench_run.py` removes the patch of an instance that goes past the
time limit:

```python
patch = capture_patch(str(repo), inst["base_commit"])
if timed_out:
    patch = ""
```

This loses correct work. In the run of 2026-09-11, `astropy__astropy-14182`
was stopped at the limit of one hour. At that moment its tree held:

```
 M astropy/io/ascii/rst.py
 M astropy/io/ascii/tests/test_rst.py
```

Those are the correct two files for that issue. The harness recorded an empty
patch.

## The work

1. Keep the patch that `capture_patch` gives, in all conditions.
2. Add a `truncated` field to the prediction row when the watchdog stopped the
   agent.
3. Keep the count of instances that go past the limit in the summary, as it is
   now.
4. Write in `bench/README.md` that a truncated patch is kept, and that the
   score step decides what to do with it.

Note that the prediction file is the durable record of a run. A row that holds
the work is better than a row that holds nothing, because you can score it
again later.

## When it is complete

- An instance that goes past the limit writes its patch.
- The row of such an instance carries `truncated`.
- The summary still says how many instances went past the limit. #bench
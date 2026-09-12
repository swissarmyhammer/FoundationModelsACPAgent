---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2b78v37nf69vkze0chscmtv
  text: |
    Picked up. What the research found, and what I chose.

    The shape that landed: `swebench_common.log(markup, **fields)` takes a CONSTANT
    message and its fields, `swebench_event.event_line` makes the text, and
    `swebench_run.py` uses that shape for each of its 20 log calls. I applied the
    same shape, and I made no second shape.

    `swebench_score.py` held SEVEN calls with an f-string, and not the four in the
    card: lines 156, 231, 266, 282, 302, 319 and 343 of the file before the change.
    The card names four; the other three are the start line, the retry line and the
    score line. All seven are now a message and its fields.

    THE CHOICE FOR `console.print`: those calls stay sentences, and the file says
    why in a comment above `parse_args`. Each one is the LAST thing the script
    writes: it names the cause, it says what a person must do, and the script then
    stops with an exit code of its own. The exit code is what a machine reads
    there, so a name and a value would give a machine nothing and make the sentence
    hard to read.

    TWO NEW NAMES in `swebench_score.py`:
    - `joined_ids(ids)` puts a group of ids in ONE field, with `ID_SEPARATOR` (a
      comma, no space) between two ids, because a space ends a field and
      `grep ids=` must find the whole group.
    - `PERCENT_PLACES` gives the percentage of a line its places, because a field
      holds a value and not a format.

    THE TEST IS A GATE, and not a copy of the code. `swebench_score.py` imports
    `swebench` and `rich`, so a unit test cannot import it; the CI job of the
    harness installs nothing. So `bench/test_swebench_log_lines.py` reads each
    `swebench_*.py` with `ast`, and it refuses a `log` call whose first argument is
    not a constant text. Two tests give the scan a source of each shape, so a scan
    that reads nothing cannot answer clean.
  timestamp: 2026-09-12T16:30:07.463539+00:00
- actor: claude-code
  id: 01m2b790t2qf7y1qvpk2x0avr7
  text: |
    ### implement — changed
    - evidence: 3 files. `bench/swebench_score.py` (7 log calls now hold a constant message and fields; new `joined_ids`, `ID_SEPARATOR`, `PERCENT_PLACES`, `LOCAL_BUILD`; a comment says why `console.print` keeps its sentences), `bench/test_swebench_log_lines.py` (new: the gate that refuses an f-string in a log call), `bench/README.md` (the shape of a score line, the new docker endpoint line, and the new test in the Files list).
    - red first: the new test reported 7 calls of `swebench_score.py`, and none of `swebench_run.py`. It is green after the change.
    - tests: `python3 -m unittest discover --start-directory bench --pattern 'test_*.py'` -> 196 tests, 0 failures, 0 warnings.
    - next: `/review`
  timestamp: 2026-09-12T16:30:13.314071+00:00
position_column: doing
position_ordinal: '80'
title: 'bench: give swebench_score.py the message-and-fields line of the run script'
---
## The condition

`swebench_run.py` now writes each milestone as a MESSAGE and its FIELDS:

```python
log("[green]done[/]", instance=instance_id, files=2, seconds=812)
```

```
09:12:31 done instance=django__django-11099 files=2 seconds=812
```

`swebench_common.log` takes the fields, `swebench_event.py` makes the text, and
a machine can then read the output of a run:
`grep instance=django__django-11099 run.log`.

`swebench_score.py` still writes f-strings, for example:

```python
log(f"[red]{len(errored)} did NOT run[/] (a build error): " + ", ".join(errored))
log(f"summary -> [bold]{out}[/]")
```

Those lines say the same thing to a person and nothing to a machine, and the
two scripts of one run thus write two shapes of line.

## The work

- Give each `log` call of `swebench_score.py` a constant message and its
  fields, as `swebench_run.py` does. `log` takes them already.
- The `console.print` calls of an error message are not milestone lines. Leave
  them, or make them fields too, but say which you chose and why.
- Read the `python/logging` rule first. It asks for key and value, and not for
  interpolation.

## When it is complete

- No `log(f"..."` stands in `bench/swebench_score.py`.
- The README of `bench/` shows the shape of a score line, as it shows the
  shape of a run line.

#bench
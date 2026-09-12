---
assignees:
- claude-code
position_column: todo
position_ordinal: 8a80
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
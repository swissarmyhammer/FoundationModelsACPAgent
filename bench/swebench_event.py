"""
swebench_event.py -- one milestone line of a run: a message and its fields.

`swebench_run.py` and `swebench_score.py` write one line for each milestone of
a run. Those lines were f-strings:

    log(f"{prefix} [green]done[/] -- {shape} . {dt:.0f}s")

A line of that shape says the same thing to a person and NOTHING to a machine.
The instance id, the count of the files and the time of the instance are in the
sentence, and a reader who wants one of them must write a regular expression.

So a line is a MESSAGE and its FIELDS. The message is a constant of the code,
and each value stands after a name of its own:

    09:12:31 done instance=django__django-11099 number=3 of=5 files=2 seconds=812

A person reads that line, and `grep instance=django__django-11099 run.log`
gives the whole story of one instance.

This module makes the text of the line. `swebench_common.py` adds the time and
gives the line to the console, because the console needs `rich`. This module
needs the standard library only, so the tests of a line need no package, as the
CI job of the harness asks.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block of
a module that the script imports.
"""
# The shape of one field: a name, the sign, and the value. No space stands
# beside the sign, because `grep instance=<id>` must find the whole field.
FIELD_SHAPE = "{name}={value}"
# What stands between the message and its first field, and between two fields.
FIELD_SEPARATOR = " "


def event_line(message, fields, quote=str):
    """The line of one milestone: what happened, and the names and values.

    - message: what happened, in the markup of the console. Give a CONSTANT
      line of the code here, because a value belongs in a field.
    - fields: the names and the values of the event, as a dict. The order of
      the dict is the order of the line, so each line of a run reads the same.
    - quote: what makes one value safe for the console. The default is `str`,
      which is what a test and a plain reader need. `swebench_common.py` gives
      the `escape` of rich, because a value such as `pip install -e .[test]`
      holds markup.

    A message with no field is the message itself, and no sign stands after
    it.
    """
    parts = [message]
    parts.extend(
        FIELD_SHAPE.format(name=name, value=quote(value))
        for name, value in fields.items()
    )
    return FIELD_SEPARATOR.join(parts)

"""
swebench_common.py -- what `swebench_run.py` and `swebench_score.py` share.

Both scripts write the same kind of message: one line, with the time, in the
rich markup of one console. That console and that function are here, so there
is one copy of each.

A line is a MESSAGE and its FIELDS, and not a sentence with the values in it:

    log("done", instance=instance_id, files=2, seconds=812)
    09:12:31 done instance=django__django-11099 files=2 seconds=812

The message is a constant of the code, so a reader of the output finds the code
that wrote it. Each value stands after a name of its own, so a machine reads
the line too: `grep instance=django__django-11099 run.log` gives the whole
story of one instance. `swebench_event.py` makes the text of the line, and it
needs no package.

This module has no PEP 723 block, because `uv run --script` reads the block of
the script it starts, and not the block of a module the script imports. Both
scripts declare `rich`, which is all this module needs.

Python puts the directory of the started script first on `sys.path`, so a
script in this directory finds this module with `import swebench_common`. The
name does not start with `swebench.`, so it does not hide the installed
`swebench` package that `swebench_score.py` imports.
"""
import time

from rich.console import Console
from rich.markup import escape

from swebench_event import event_line

# The one console of a run. Each script uses it for its own output too: the
# rule at the start, the table at the end, and the error messages.
#
# Everything goes to standard output, and no script writes a log file. To keep
# a record, send standard output where you want it:
#
#     uv run bench/swebench_run.py bench/preds.jsonl | tee bench/run.log
#
# rich finds that standard output is not a terminal, and it then writes plain
# text with no color.
console = Console()
# The time of a line, as a person of a long run reads it.
TIME_SHAPE = "%H:%M:%S"
# The shape of one line: the time, and then the event.
LINE_SHAPE = "[dim]{time}[/] {event}"


def quoted(value):
    """One value of a field, as text that the console prints and does not read.

    - value: the value of the field.

    The `escape` of rich is what makes `pip install -e .[test]` text. Without
    it the console reads `[test]` as a tag of its markup.
    """
    return escape(str(value))


def log(markup, **fields):
    """Write one milestone line, with the time and the fields of the event.

    - markup: what happened, in rich markup. Give a CONSTANT line here, and
      not an f-string: a value belongs in a field, where a reader of the log
      finds it by its name.
    - fields: the names and the values of the event, for example
      `instance="django__django-11099"`. A milestone with nothing to say gives
      none.

    The line is written with `soft_wrap`, so the console does not break it at
    the width of the terminal. One milestone is ONE line, and a field of it
    thus stands whole for `grep`.
    """
    ts = time.strftime(TIME_SHAPE)
    event = event_line(markup, fields, quote=quoted)
    console.print(
        LINE_SHAPE.format(time=ts, event=event), highlight=False, soft_wrap=True
    )

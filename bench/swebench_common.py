"""
swebench_common.py -- what `swebench_run.py` and `swebench_score.py` share.

Both scripts write the same kind of message: one line, with the time, in the
rich markup of one console. That console and that function are here, so there
is one copy of each.

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

# The one console of a run. Each script uses it for its own output too: the
# rule at the start, the table at the end, and the error messages.
#
# Everything goes to standard output, and no script writes a log file. To keep
# a record, send standard output where you want it:
#
#     uv run bench/swebench_run.py preds.jsonl | tee run.log
#
# rich finds that standard output is not a terminal, and it then writes plain
# text with no color.
console = Console()


def log(markup):
    """Write one milestone line, with the time.

    - markup: the text of the line, in rich markup.
    """
    ts = time.strftime("%H:%M:%S")
    console.print(f"[dim]{ts}[/] {markup}", highlight=False)

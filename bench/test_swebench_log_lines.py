#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_log_lines.py -- the proof that no log call holds an f-string.

`swebench_common.log` takes a MESSAGE and its FIELDS:

    log("done", instance=instance_id, files=2, seconds=812)
    09:12:31 done instance=django__django-11099 files=2 seconds=812

The message is a constant of the code, so a reader of the output finds the line
of the code that wrote it. Each value stands after a name of its own, so a
machine reads the line too: `grep instance=django__django-11099 run.log` gives
the whole story of one instance.

An f-string breaks both halves. The message is no longer a constant, and the
value in it has no name:

    log(f"[red]{len(errored)} did NOT run[/]: " + ", ".join(errored))

So this test reads each script of the harness with `ast`, and it refuses a
`log` call whose first argument is not a constant text. The scripts of one run
thus write one shape of line.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_log_lines.py
    python3 bench/test_swebench_log_lines.py
"""
import ast
import unittest
from pathlib import Path

# The directory of the harness. Each script and each module of a run stands
# here.
BENCH = Path(__file__).parent
# What the scan reads: each module and each script of the harness. A new script
# thus comes under this gate on the day a person writes it, and no person must
# remember to add it here.
HARNESS_SHAPE = "swebench_*.py"
# The name of the function that writes one milestone line.
LOG_NAME = "log"
# What a person reads when a call gives no constant message.
REFUSED = "{name}:{line}: the message of `{function}` is not a constant"
# The two sources a test gives the scan, to prove that the scan reads a call.
# A scan that finds nothing in every file proves nothing on its own.
A_SOURCE_WITH_AN_F_STRING = 'log(f"done {instance}")\n'
A_SOURCE_WITH_A_CONSTANT = 'log("done", instance=instance)\n'
# The line of the one call in each of those two sources.
THE_FIRST_LINE = 1


def harness_files():
    """The files of the harness that the scan reads.

    The list holds each module and each script of a run, and no test. A test
    holds a `log` call of its own only as an example in its text.
    """
    return sorted(BENCH.glob(HARNESS_SHAPE))


def constant_text(node):
    """Whether one argument of a call is a constant text.

    - node: the first argument of a `log` call.

    Python joins two texts that stand beside each other into ONE constant, so
    a message that a person wrote over three lines is a constant here.
    """
    return isinstance(node, ast.Constant) and isinstance(node.value, str)


def calls_with_no_constant_message(source):
    """The line of each `log` call whose message is not a constant.

    - source: the text of one Python file.

    A call gives its message first, so the scan reads the first argument of
    each `log` call. A constant text is what the rule asks for. An f-string, a
    sum of two texts, and a name are each refused, because a reader of the
    output cannot find such a message in the code.
    """
    refused = []
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, ast.Call):
            continue
        if getattr(node.func, "id", None) != LOG_NAME:
            continue
        if not node.args or not constant_text(node.args[0]):
            refused.append(node.lineno)
    return refused


class TheMessageOfEachLogCall(unittest.TestCase):
    """What each script of the harness gives `log` as its message."""

    def test_the_scan_finds_an_f_string(self):
        """The scan must find the shape it refuses, or it proves nothing."""
        self.assertEqual(
            calls_with_no_constant_message(A_SOURCE_WITH_AN_F_STRING),
            [THE_FIRST_LINE],
        )

    def test_the_scan_keeps_a_constant_message(self):
        """A message and its fields is the shape the harness writes."""
        self.assertEqual(
            calls_with_no_constant_message(A_SOURCE_WITH_A_CONSTANT), []
        )

    def test_the_scan_reads_the_two_scripts_of_a_run(self):
        """A scan that reads no file answers clean, and says nothing."""
        names = {path.name for path in harness_files()}
        self.assertIn("swebench_run.py", names)
        self.assertIn("swebench_score.py", names)

    def test_no_log_call_of_the_harness_holds_an_f_string(self):
        """One run has two scripts, and they write one shape of line."""
        refused = []
        for path in harness_files():
            refused.extend(
                REFUSED.format(name=path.name, line=line, function=LOG_NAME)
                for line in calls_with_no_constant_message(path.read_text())
            )
        self.assertEqual(refused, [])


if __name__ == "__main__":
    unittest.main()

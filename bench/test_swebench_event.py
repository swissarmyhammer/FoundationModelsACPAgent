#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_event.py -- the proof that a milestone line holds names and
values.

`swebench_run.py` wrote each line of a run with an f-string:

    log(f"{prefix} [green]done[/] -- {shape} . {dt:.0f}s")

A line of that shape cannot be read by a machine. A person who wants the time
of one instance, or the count of the instances that made no patch, must read
the line with the eye or write a regular expression for it.

So a line is now a MESSAGE and its FIELDS. The message is a constant of the
code, and each value stands after a name of its own:

    09:12:31 done instance=django__django-11099 number=3 of=5 files=2 seconds=812

`grep instance=django__django-11099 run.log` then gives the whole story of one
instance.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_event.py
    python3 bench/test_swebench_event.py
"""
import unittest

from swebench_event import event_line

# The names below are the names of a test, and not the names of this machine.
A_MESSAGE = "the environment is ready"
AN_INSTANCE = "django__django-11099"
A_SECONDS_COUNT = 12
# What a stand-in `quote` makes of each value. A test reads this name in the
# line, and it thus knows that the line went through `quote`.
A_SAFE_VALUE = "safe"


def a_quote(value):
    """A stand-in for the function that makes a value safe for the console.

    - value: the value of a field.

    `swebench_common.py` gives the `escape` of rich here. This module needs no
    package, so a test gives this one.
    """
    return A_SAFE_VALUE


class TheLineOfOneMilestone(unittest.TestCase):
    """What a run writes for one milestone."""

    def test_a_message_with_no_field_is_the_message(self):
        """A milestone with nothing to say holds no field, and no sign."""
        self.assertEqual(event_line(A_MESSAGE, {}), A_MESSAGE)

    def test_a_field_is_a_name_and_a_value(self):
        """This is the shape that `grep` and a person both read."""
        line = event_line(A_MESSAGE, {"instance": AN_INSTANCE})
        self.assertIn("instance=" + AN_INSTANCE, line)

    def test_the_message_stands_first(self):
        """A reader of a run reads what happened, and then the values."""
        line = event_line(A_MESSAGE, {"instance": AN_INSTANCE})
        self.assertTrue(line.startswith(A_MESSAGE))

    def test_the_fields_keep_their_order(self):
        """The caller gives the order, so each line of a run reads the same."""
        line = event_line(
            A_MESSAGE, {"instance": AN_INSTANCE, "seconds": A_SECONDS_COUNT}
        )
        self.assertLess(line.index("instance="), line.index("seconds="))

    def test_a_value_that_is_a_number_becomes_text(self):
        """A count and a time are numbers, and a line is text."""
        line = event_line(A_MESSAGE, {"seconds": A_SECONDS_COUNT})
        self.assertIn("seconds=" + str(A_SECONDS_COUNT), line)

    def test_each_value_goes_through_the_quote_of_the_caller(self):
        """A value such as `pip install -e .[test]` holds markup.

        Without the quote of the caller, the console reads `[test]` as a tag
        and it stops with an error.
        """
        line = event_line(A_MESSAGE, {"install": ".[test]"}, quote=a_quote)
        self.assertIn("install=" + A_SAFE_VALUE, line)


if __name__ == "__main__":
    unittest.main()

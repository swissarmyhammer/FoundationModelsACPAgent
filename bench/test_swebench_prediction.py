#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_prediction.py -- the proof that a run keeps the work it made.

The predictions file is the durable record of a run. A row that holds the work
is better than a row that holds nothing, because you can score it again later.

Before this module, `swebench_run.py` removed the patch of an instance that
went past the time limit. The run of 2026-09-11 shows what that costs. The
watchdog stopped `astropy__astropy-14182` at the limit of one hour, and the
tree of that instance held two changed files:

    M astropy/io/ascii/rst.py
    M astropy/io/ascii/tests/test_rst.py

Those are the correct two files for that issue. The harness recorded an empty
patch. These tests hold the new behaviour: the row keeps the patch, and it
says that the watchdog stopped the agent.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_prediction.py
    python3 bench/test_swebench_prediction.py
"""
import json
import unittest

from swebench_prediction import prediction_row

# The names below are the names of a test. The instance is the one that lost
# its work in the run of 2026-09-11.
INSTANCE_ID = "astropy__astropy-14182"
MODEL_NAME = "acp-agent"
# A patch with the shape that `git diff <base_commit>` gives. The text is
# short, because these tests read the row and not the diff.
A_PATCH = (
    "diff --git a/astropy/io/ascii/rst.py b/astropy/io/ascii/rst.py\n"
    "--- a/astropy/io/ascii/rst.py\n"
    "+++ b/astropy/io/ascii/rst.py\n"
    "@@ -1,1 +1,1 @@\n"
    "-    header_rows = None\n"
    "+    header_rows = [\"name\"]\n"
)


class TheRowOfAStoppedInstance(unittest.TestCase):
    """The row of an instance that the watchdog stopped at the time limit."""

    def stopped_row(self, patch=A_PATCH):
        """The row of an instance that the watchdog stopped.

        - patch: the diff that the tree held at the limit.
        """
        return prediction_row(INSTANCE_ID, MODEL_NAME, patch, truncated=True)

    def test_it_keeps_the_patch(self):
        """This is the defect the task names.

        The old harness wrote an empty patch here, and the correct work of
        `astropy__astropy-14182` was lost with it.
        """
        self.assertEqual(self.stopped_row()["model_patch"], A_PATCH)

    def test_it_says_that_the_watchdog_stopped_the_agent(self):
        """The score step must be able to tell a stopped run from a whole one.

        Without this field, a kept patch and a finished patch read the same.
        """
        self.assertIs(self.stopped_row()["truncated"], True)

    def test_it_keeps_an_empty_patch_empty(self):
        """A stopped agent that changed nothing must not get a false patch."""
        self.assertEqual(self.stopped_row(patch="")["model_patch"], "")


class TheRowOfAFinishedInstance(unittest.TestCase):
    """The row of an instance that the agent finished inside the time limit."""

    def finished_row(self, patch=A_PATCH):
        """The row of an instance that the agent finished.

        - patch: the diff that the agent made.
        """
        return prediction_row(INSTANCE_ID, MODEL_NAME, patch, truncated=False)

    def test_it_carries_no_truncated_field(self):
        """A finished row must keep the shape that earlier runs wrote.

        A predictions file grows across runs. The rows of the earlier runs
        have three keys, and a reader of the field uses `get`.
        """
        self.assertNotIn("truncated", self.finished_row())

    def test_it_keeps_the_patch(self):
        """The patch of a finished agent is the answer of the instance."""
        self.assertEqual(self.finished_row()["model_patch"], A_PATCH)


class TheKeysOfTheRow(unittest.TestCase):
    """The names that the official SWE-bench harness reads from each row."""

    def test_it_names_the_instance_and_the_model(self):
        """The harness finds the instance and the report name with these."""
        row = prediction_row(INSTANCE_ID, MODEL_NAME, A_PATCH, truncated=False)
        self.assertEqual(row["instance_id"], INSTANCE_ID)
        self.assertEqual(row["model_name_or_path"], MODEL_NAME)

    def test_it_goes_to_disk_and_comes_back_whole(self):
        """A run writes one row as one JSON line, and a score step reads it.

        This proves the write side and the read side agree, and that a patch
        with newlines in it survives the two steps.
        """
        row = prediction_row(INSTANCE_ID, MODEL_NAME, A_PATCH, truncated=True)
        line = json.dumps(row) + "\n"
        self.assertNotIn("\n", line[:-1])
        self.assertEqual(json.loads(line), row)


if __name__ == "__main__":
    unittest.main()

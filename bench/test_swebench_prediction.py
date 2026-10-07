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

The score step reads the file with `load_predictions`. The tests of
`TheSubmittedCountOfAScore` hold that the submitted count comes from the whole
file, and not from the ids of `--instance-ids`.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_prediction.py
    python3 bench/test_swebench_prediction.py
"""
import json
import tempfile
import unittest
from pathlib import Path

from swebench_prediction import load_predictions, prediction_row

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
# The run `code-context-1006` held 16 predictions. Its score stopped, and the
# resume sent 3 of them again with `--instance-ids`.
FILE_SIZE = 16
# The 3 ids of that resume.
RESUMED_IDS = (
    "django__django-14608",
    "django__django-14667",
    "django__django-14672",
)
# The number of the first of the other ids. It is below each resumed id, so no
# other id is the same as a resumed id.
FIRST_OTHER_NUMBER = 10000
# The ids of the 13 other predictions of the file.
OTHER_IDS = tuple(
    f"django__django-{number}"
    for number in range(
        FIRST_OTHER_NUMBER, FIRST_OTHER_NUMBER + FILE_SIZE - len(RESUMED_IDS)
    )
)


def a_predictions_file(directory, instance_ids):
    """Write one prediction row for each id, and give the path of the file.

    - directory: the directory that gets the file.
    - instance_ids: the ids of the rows, in their order.
    """
    path = Path(directory) / "preds.jsonl"
    lines = (
        json.dumps(prediction_row(i, MODEL_NAME, A_PATCH, truncated=False))
        for i in instance_ids
    )
    path.write_text("".join(f"{line}\n" for line in lines))
    return path


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


class TheSubmittedCountOfAScore(unittest.TestCase):
    """How many predictions a score run counts as sent.

    The resume of `code-context-1006` on 2026-10-06 printed `submitted=3
    percent_of_submitted=400.0`. The tally read each report of the run id, and
    it found 12 resolved of 15 evaluated. But the submitted count was the
    count of `--instance-ids`, and not the 16 predictions of the file.
    """

    def test_it_counts_each_prediction_of_the_file_and_not_the_chosen_ids(self):
        """The defect that task ^60mtc3r names.

        A file of 16 rows and 3 `--instance-ids` sent 16 predictions. A
        count of 3 makes the percent of submitted more than 100.
        """
        with tempfile.TemporaryDirectory() as directory:
            path = a_predictions_file(directory, OTHER_IDS + RESUMED_IDS)
            predictions = load_predictions(path, list(RESUMED_IDS))
        self.assertEqual(predictions.submitted, FILE_SIZE)

    def test_it_scores_the_chosen_ids_only(self):
        """`--instance-ids` still chooses the instances that go to docker."""
        with tempfile.TemporaryDirectory() as directory:
            path = a_predictions_file(directory, OTHER_IDS + RESUMED_IDS)
            predictions = load_predictions(path, list(RESUMED_IDS))
        chosen = [row["instance_id"] for row in predictions.rows]
        self.assertEqual(chosen, list(RESUMED_IDS))

    def test_it_counts_an_instance_one_time(self):
        """The harness keeps one prediction for each instance id.

        A file with a row two times thus sends one prediction for that id.
        """
        with tempfile.TemporaryDirectory() as directory:
            path = a_predictions_file(
                directory, OTHER_IDS + RESUMED_IDS + RESUMED_IDS[:1]
            )
            predictions = load_predictions(path, None)
        self.assertEqual(predictions.submitted, FILE_SIZE)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_report.py -- the proof that the score report says the truth.

The report of a score run is the number that a person quotes. So it must say
what the agent did, and it must not say anything else.

Three rules hold that, and these tests hold the three rules:

  * The score is resolved / EVALUATED. An instance that did not run, because
    docker could not build its image, stays out of the divisor. A memory
    failure of this machine is not a failure of the agent.
  * A run that evaluated NOTHING writes no report. The run of the task wrote
    `"submitted": 16, "evaluated": 0, "resolved": 0`, and that file reads like
    a failure of the agent although docker was the cause.
  * The report stands beside the predictions, and NOWHERE else. The run id
    comes from the command line and it becomes part of the path of the
    report, so a run id that is not a name is refused.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_report.py
    python3 bench/test_swebench_report.py
"""
import json
import tempfile
import unittest
from pathlib import Path

from swebench_report import (
    RunIdError,
    report_path,
    score_report,
    write_report,
)

# The names below are the names of a test. A run id of a score step holds the
# time, as `score_20260912_090000` does.
A_RUN_ID = "score_20260912_090000"
# The run id of the finding: it writes the report outside the directory of
# the predictions.
A_CLIMB = "../../etc/hostname"
# Run ids that a person must never be able to give. The run id comes from the
# command line, and it becomes part of a path, so each one of these either
# leaves the directory of the predictions or is not a name at all.
BAD_RUN_IDS = (
    A_CLIMB,               # the climb: it writes the report somewhere else
    "..",                  # a climb by itself, as in `logs/run_evaluation/..`
    ".",                   # the directory itself, and not a name in it
    "/etc/hostname",       # an absolute path
    "..\\..\\etc",         # the climb of the other platform
    ".hidden",             # a name that begins with a dot, as `.` and `..` do
    "",                    # no name at all
    "score $(whoami)",     # the words of a shell
    "score\n2026",         # a second line
)
A_PREDICTIONS_FILE = Path("/a/b/preds.jsonl")
# Three instances of SWE-bench_Lite: one resolved, one not resolved, and one
# that docker could not build.
RESOLVED_ID = "django__django-10914"
UNRESOLVED_ID = "psf__requests-2317"
ERRORED_ID = "astropy__astropy-14182"
# The wall time of a score run, in minutes.
A_WALL_TIME = 12.5


def a_report(run_id=A_RUN_ID, **changes):
    """The report of a run of three instances, with the given changes.

    - run_id: the run id of the harness.
    - changes: the fields to replace.
    """
    fields = {
        "predictions": A_PREDICTIONS_FILE,
        "submitted": 3,
        "evaluated": [RESOLVED_ID, UNRESOLVED_ID],
        "resolved": [RESOLVED_ID],
        "errored": [ERRORED_ID],
        "minutes": A_WALL_TIME,
    }
    fields.update(changes)
    return score_report(run_id, **fields)


class TheReportFile(unittest.TestCase):
    """Where the report of a score run stands."""

    def test_it_stands_beside_the_predictions_file(self):
        """The `.gitignore` of `bench/` keeps the results of a run out of git.

        A report beside the predictions is thus ignored with them.
        """
        path = report_path(A_PREDICTIONS_FILE, A_RUN_ID)
        self.assertEqual(path.parent, A_PREDICTIONS_FILE.parent)

    def test_it_names_the_run_in_the_name_of_the_file(self):
        """You can score one predictions file many times.

        A second run must not write over the report of the first.
        """
        path = report_path(A_PREDICTIONS_FILE, A_RUN_ID)
        self.assertEqual(path.name, f"preds.jsonl.score.{A_RUN_ID}.json")


class TheRunIdOfAReport(unittest.TestCase):
    """Which run ids can become part of the path of the report.

    `--run-id` comes from the command line, and the run id then becomes part
    of the name of the report file and part of the directory of the harness
    logs. A run id such as `../../etc/hostname` would put the report outside
    the directory of the predictions. So a run id must be a NAME.
    """

    def test_the_path_refuses_a_run_id_that_is_not_a_name(self):
        """The report can only ever stand beside the predictions file."""
        for run_id in BAD_RUN_IDS:
            with self.subTest(run_id=run_id):
                with self.assertRaises(RunIdError):
                    report_path(A_PREDICTIONS_FILE, run_id)

    def test_the_report_refuses_a_run_id_that_is_not_a_name(self):
        """`score_report` is the second door to the path.

        It puts the run id in the report, and `write_report` reads it back
        to make the path. A gate on `report_path` alone leaves this door
        open.
        """
        for run_id in BAD_RUN_IDS:
            with self.subTest(run_id=run_id):
                with self.assertRaises(RunIdError):
                    a_report(run_id)

    def test_the_refusal_names_the_run_id(self):
        """A person who gave a bad run id must read which one it was.

        A message that says only "the run id is not a name" makes the person
        read the command line again to find the answer.
        """
        with self.assertRaises(RunIdError) as refusal:
            report_path(A_PREDICTIONS_FILE, A_CLIMB)
        self.assertIn(A_CLIMB, str(refusal.exception))

    def test_it_takes_a_run_id_of_capital_letters(self):
        """A run id is a name, and the case of a name is free.

        The score step makes a run id of small letters, and a person can give
        `--run-id RESCORE`. The report of that run is a file like any other.
        """
        path = report_path(A_PREDICTIONS_FILE, A_RUN_ID.upper())
        self.assertEqual(path.parent, A_PREDICTIONS_FILE.parent)
        self.assertEqual(
            path.name, f"preds.jsonl.score.{A_RUN_ID.upper()}.json"
        )


class TheScoreOfARun(unittest.TestCase):
    """What the report says about the instances of a run."""

    def test_it_names_the_run_and_the_predictions(self):
        """A report away from its two sources says nothing by itself."""
        report = a_report()
        self.assertEqual(report["run_id"], A_RUN_ID)
        self.assertEqual(report["predictions"], str(A_PREDICTIONS_FILE))

    def test_it_counts_what_was_sent_evaluated_and_resolved(self):
        """These three counts are the summary of a run."""
        report = a_report()
        self.assertEqual(report["submitted"], 3)
        self.assertEqual(report["evaluated"], 2)
        self.assertEqual(report["resolved"], 1)

    def test_it_counts_the_instances_that_ran_and_did_not_resolve(self):
        """An instance that ran and failed is a failure of the agent."""
        self.assertEqual(a_report()["unresolved"], 1)

    def test_it_names_the_ids_of_each_group(self):
        """A person who reads the report must find the instances again."""
        report = a_report()
        self.assertEqual(report["resolved_ids"], [RESOLVED_ID])
        self.assertEqual(report["unresolved_ids"], [UNRESOLVED_ID])
        self.assertEqual(report["errored_ids"], [ERRORED_ID])

    def test_it_divides_by_the_instances_that_were_evaluated(self):
        """This is the honest number: one of the two that ran resolved.

        The instance that did not run stays out of the divisor, because a
        build error of docker is not a failure of the agent.
        """
        self.assertEqual(a_report()["resolved_pct_of_evaluated"], 50.0)

    def test_it_also_gives_the_part_of_the_instances_that_were_sent(self):
        """The other number a reader wants: one of the three that were sent."""
        self.assertAlmostEqual(
            a_report()["resolved_pct_of_submitted"], 100 / 3
        )

    def test_it_gives_no_percentage_when_nothing_was_evaluated(self):
        """A divisor of zero must give a number, and not an error."""
        report = a_report(evaluated=[], resolved=[], submitted=0)
        self.assertEqual(report["resolved_pct_of_evaluated"], 0.0)
        self.assertEqual(report["resolved_pct_of_submitted"], 0.0)

    def test_it_holds_the_wall_time_of_the_run(self):
        """A score run of many hours must say how long it was."""
        self.assertEqual(a_report()["wall_minutes"], A_WALL_TIME)


class TheReportOnDisk(unittest.TestCase):
    """Which runs write a report, and which do not."""

    def test_it_writes_the_report_beside_the_predictions(self):
        """A run that scored something keeps its number on disk."""
        with tempfile.TemporaryDirectory() as directory:
            predictions = Path(directory) / "preds.jsonl"
            report = a_report(predictions=predictions)
            written = write_report(predictions, report)
            self.assertEqual(written, report_path(predictions, A_RUN_ID))
            self.assertTrue(written.exists())

    def test_the_report_comes_back_whole(self):
        """A reader of the file must get the report the run made."""
        with tempfile.TemporaryDirectory() as directory:
            predictions = Path(directory) / "preds.jsonl"
            report = a_report(predictions=predictions)
            written = write_report(predictions, report)
            self.assertEqual(json.loads(written.read_text()), report)

    def test_it_writes_no_file_when_no_instance_was_evaluated(self):
        """This is the defect that the task names.

        Docker did not run, each of the instances failed, and the report said
        `"resolved": 0`. That file reads like a failure of the agent.
        """
        with tempfile.TemporaryDirectory() as directory:
            predictions = Path(directory) / "preds.jsonl"
            report = a_report(
                predictions=predictions,
                evaluated=[],
                resolved=[],
                errored=[RESOLVED_ID, UNRESOLVED_ID, ERRORED_ID],
            )
            write_report(predictions, report)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_it_writes_nothing_when_the_run_id_is_not_a_name(self):
        """A report can come from a file, and not only from `score_report`.

        The run id of such a report went through no gate, so `write_report`
        refuses it too. Nothing goes to disk, here or anywhere else.
        """
        with tempfile.TemporaryDirectory() as directory:
            predictions = Path(directory) / "preds.jsonl"
            report = dict(a_report(predictions=predictions), run_id="..")
            with self.assertRaises(RunIdError):
                write_report(predictions, report)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_it_names_no_file_when_no_instance_was_evaluated(self):
        """The caller reads this answer, and it then says why it stopped."""
        with tempfile.TemporaryDirectory() as directory:
            predictions = Path(directory) / "preds.jsonl"
            report = a_report(predictions=predictions, evaluated=[], resolved=[])
            self.assertIsNone(write_report(predictions, report))


if __name__ == "__main__":
    unittest.main()

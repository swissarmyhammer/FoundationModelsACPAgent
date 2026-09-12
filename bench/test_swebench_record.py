#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_record.py -- the proof that a run records each instance.

A run of `swebench_run.py` writes the duration, the exit code and the count of
rounds to standard output alone. The run of 2026-09-11 kept no log, so nobody
could say why the instances were slow. All of the time data had to be built
again from the transcripts.

These tests hold the new behaviour. Each instance gets one row in a second
file beside the predictions, and that row holds the durations, the exit code
and the shape of the patch. The row goes to disk when the instance ends, so a
run that stops in the middle keeps the rows of the instances that are
complete.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_record.py
    python3 bench/test_swebench_record.py
"""
import json
import tempfile
import unittest
from pathlib import Path

from swebench_record import append_row, patch_file_count, run_record, runs_path

# The names below are the names of a test. The instance is the one that went
# past the time limit in the run of 2026-09-11.
INSTANCE_ID = "astropy__astropy-14182"
# A patch of two files, with the shape that `git diff <base_commit>` gives.
A_PATCH = (
    "diff --git a/astropy/io/ascii/rst.py b/astropy/io/ascii/rst.py\n"
    "--- a/astropy/io/ascii/rst.py\n"
    "+++ b/astropy/io/ascii/rst.py\n"
    "@@ -1,1 +1,1 @@\n"
    "-    header_rows = None\n"
    '+    header_rows = ["name"]\n'
    "diff --git a/astropy/io/ascii/tests/test_rst.py"
    " b/astropy/io/ascii/tests/test_rst.py\n"
    "--- a/astropy/io/ascii/tests/test_rst.py\n"
    "+++ b/astropy/io/ascii/tests/test_rst.py\n"
    "@@ -1,1 +1,2 @@\n"
    "+def test_header_rows():\n"
)
# A patch of one file, with a character that needs two bytes in UTF-8. It is
# 28 characters long, and 29 bytes long.
A_PATCH_WITH_A_WIDE_CHARACTER = "diff --git a/x.py b/x.py\n+é\n"
BYTES_OF_THE_WIDE_PATCH = 29
# Where `keep_transcripts` puts the transcripts of this instance.
A_TRANSCRIPT_PATH = f"/tmp/preds.transcripts/{INSTANCE_ID}"
# The nine names that the record of an instance carries. A reader of the file
# expects all of them in every row.
RECORD_KEYS = {
    "instance_id",
    "seconds",
    "clone_seconds",
    "agent_seconds",
    "exit_code",
    "timed_out",
    "patch_bytes",
    "patch_files",
    "transcript_path",
}


def a_record(**changes):
    """The record of one instance that finished, with the given changes.

    - changes: the fields to replace.
    """
    fields = {
        "seconds": 1837.5,
        "clone_seconds": 12.25,
        "agent_seconds": 1820.0,
        "exit_code": 0,
        "timed_out": False,
        "patch": A_PATCH,
        "transcript_path": A_TRANSCRIPT_PATH,
    }
    fields.update(changes)
    return run_record(INSTANCE_ID, **fields)


class TheRunsFile(unittest.TestCase):
    """Where the record of a run stands."""

    def test_it_takes_the_name_from_the_predictions_file(self):
        """The two files of one run must be easy to pair.

        The transcripts of a run follow the same rule, so a reader learns
        one rule and finds every result of a run.
        """
        self.assertEqual(
            runs_path(Path("preds.jsonl")).name, "preds.runs.jsonl"
        )

    def test_it_stands_in_the_directory_of_the_predictions_file(self):
        """The `.gitignore` of `bench/` keeps the results of a run out of git.

        A record beside the predictions is thus ignored with them. A record
        in the directory of work makes the tree dirty.
        """
        self.assertEqual(
            runs_path(Path("/a/b/run7.jsonl")), Path("/a/b/run7.runs.jsonl")
        )


class TheRecordOfAnInstance(unittest.TestCase):
    """What one row of the record holds."""

    def test_it_names_the_instance(self):
        """A reader joins the record to the predictions with this name."""
        self.assertEqual(a_record()["instance_id"], INSTANCE_ID)

    def test_it_holds_the_time_of_the_instance_and_of_its_two_steps(self):
        """This is the data the run of 2026-09-11 lost.

        The whole time alone does not say if the clone or the agent was
        slow. The two steps answer that question.
        """
        record = a_record()
        self.assertEqual(record["seconds"], 1837.5)
        self.assertEqual(record["clone_seconds"], 12.25)
        self.assertEqual(record["agent_seconds"], 1820.0)

    def test_it_rounds_each_time_to_milliseconds(self):
        """A clock gives more digits than a reader of a run can use."""
        record = a_record(seconds=12.3456789, clone_seconds=0.00049)
        self.assertEqual(record["seconds"], 12.346)
        self.assertEqual(record["clone_seconds"], 0.0)

    def test_it_holds_the_exit_code_of_the_agent(self):
        """An agent that stopped with an error must be easy to find."""
        self.assertEqual(a_record(exit_code=2)["exit_code"], 2)

    def test_it_says_when_the_watchdog_stopped_the_instance(self):
        """The score step reads this to tell a stopped run from a whole one."""
        self.assertIs(a_record(timed_out=True)["timed_out"], True)

    def test_it_names_where_the_transcripts_are(self):
        """The transcripts say what the model did in each round.

        Without this name a reader must build the path again by hand.
        """
        self.assertEqual(
            a_record()["transcript_path"], A_TRANSCRIPT_PATH
        )

    def test_it_makes_a_path_into_text(self):
        """`keep_transcripts` gives a `Path`, and JSON holds text alone."""
        record = a_record(transcript_path=Path(A_TRANSCRIPT_PATH))
        self.assertEqual(record["transcript_path"], A_TRANSCRIPT_PATH)

    def test_it_holds_the_nine_names_when_the_clone_failed(self):
        """A step that did not run gives no number, but the row keeps shape.

        An instance that failed in the clone has no agent and no patch. Its
        row must still carry every name, so that a reader can use `[]` on
        each row of the file.
        """
        record = run_record(
            INSTANCE_ID,
            seconds=3.5,
            clone_seconds=None,
            agent_seconds=None,
            exit_code=None,
            timed_out=False,
            patch="",
            transcript_path=None,
        )
        self.assertEqual(set(record), RECORD_KEYS)
        self.assertIsNone(record["clone_seconds"])
        self.assertIsNone(record["agent_seconds"])
        self.assertIsNone(record["exit_code"])
        self.assertIsNone(record["transcript_path"])

    def test_it_holds_the_nine_names_when_the_instance_finished(self):
        """The rows of one file must all have the same shape."""
        self.assertEqual(set(a_record()), RECORD_KEYS)


class ThePatchOfARecord(unittest.TestCase):
    """What the record says about the patch the agent made."""

    def test_it_counts_the_files_of_the_patch(self):
        """A patch of many files is a different answer from a patch of one."""
        self.assertEqual(a_record()["patch_files"], 2)

    def test_it_measures_the_patch_in_bytes(self):
        """A byte is what the predictions file holds, and a character is not.

        This patch carries a character that needs two bytes in UTF-8.
        """
        record = a_record(patch=A_PATCH_WITH_A_WIDE_CHARACTER)
        self.assertEqual(record["patch_bytes"], BYTES_OF_THE_WIDE_PATCH)

    def test_an_empty_patch_holds_no_file_and_no_byte(self):
        """An agent that changed nothing must not get a false measure."""
        record = a_record(patch="")
        self.assertEqual(record["patch_bytes"], 0)
        self.assertEqual(record["patch_files"], 0)

    def test_it_counts_no_file_for_a_header_inside_the_patch_body(self):
        """A patch can ADD a line that looks like a header.

        Each line of a body starts with a space, a `+` or a `-`, so a
        header is the only line that starts with the word itself.
        """
        body = "diff --git a/x.py b/x.py\n+diff --git a/y.py b/y.py\n"
        self.assertEqual(patch_file_count(body), 1)

    def test_it_reads_the_header_of_git_in_lower_case_only(self):
        """`git diff` writes this header in lower case, in all conditions.

        The word in upper case is thus content of the patch, and not a
        header. A match without case would count it, and the count of files
        would then be too high.
        """
        self.assertEqual(patch_file_count("DIFF --GIT a/x.py b/x.py\n"), 0)


class TheRowsOnDisk(unittest.TestCase):
    """How the rows of a run reach the disk."""

    def rows_of_a_file(self, path):
        """The rows that a file holds, read again from the disk.

        - path: the file to read.
        """
        return [json.loads(line) for line in path.read_text().splitlines()]

    def test_a_row_is_on_disk_before_the_run_ends(self):
        """A run of many hours can stop at any instance.

        The rows of the instances that are complete must survive that. So
        this test reads the file while the stream is still OPEN.
        """
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preds.runs.jsonl"
            with path.open("a") as stream:
                append_row(stream, a_record())
                self.assertEqual(len(self.rows_of_a_file(path)), 1)

    def test_a_row_goes_to_disk_and_comes_back_whole(self):
        """A reader of the file must get the record the run made."""
        record = a_record()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preds.runs.jsonl"
            with path.open("a") as stream:
                append_row(stream, record)
            self.assertEqual(self.rows_of_a_file(path), [record])

    def test_a_run_of_two_instances_writes_two_rows(self):
        """This is the measure the task names.

        Each instance gets one row, and the rows keep the order of the run.
        """
        first = a_record()
        second = run_record(
            "django__django-11099",
            seconds=60.0,
            clone_seconds=5.0,
            agent_seconds=55.0,
            exit_code=0,
            timed_out=False,
            patch="",
            transcript_path=None,
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preds.runs.jsonl"
            with path.open("a") as stream:
                append_row(stream, first)
                append_row(stream, second)
            self.assertEqual(self.rows_of_a_file(path), [first, second])


if __name__ == "__main__":
    unittest.main()

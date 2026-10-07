#!/usr/bin/env python3
"""test_scan.py -- the proof that scan.py counts the 'running' notices by
operation, and that it does not show a stopped run as a live run.

On 2026-10-05 scan.py said "18173 'running' notices" for the run
`code-context`. That was the count of transcript rows: one execute operation
of django__django-14667 wrote 13663 of them. On the old log
`run.code-context.log.web-off-0717` it also said "django__django-13447 runs
16347s of its 5400s limit", for a run that had stopped two days before. And it
did not tell that the old log and the transcripts were of two different runs.
These tests hold the correct behaviour (task ^5m3n22z).

Each test writes a small fake run log, predictions and transcripts into a
temporary directory. The tests need the standard library only:

    python3 -m unittest discover --start-directory .claude/skills/swebench/scripts
"""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("swebench_scan_script", HERE / "scan.py")
scan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scan)

# The instances of the fake runs.
FIRST, SECOND = "django__django-13447", "django__django-14667"
# The time limit of an instance in the fake logs, in seconds.
LIMIT = 5400
# The time of the first agent line of the old fake run (local time). It is the
# time of the old log of 2026-10-05.
OLD_START = dt.datetime(2026, 10, 5, 7, 10, 26)
# The time from the "running the agent" line to the first transcript line in
# a real run is 10 to 26 seconds.
SAME_RUN_DELAY = dt.timedelta(seconds=15)
# The delay of the transcripts of the new run after the line of the old log.
OTHER_RUN_DELAY = dt.timedelta(seconds=488)
# The time from the last log line to the last change of the log file.
WRITE_DELAY = dt.timedelta(seconds=60)
# The count of single-byte writes of the command of task ^p8c7snm: one write
# for each test, as the Django test runner writes one "." for each test.
ONE_BYTE_WRITES = 10000


def clock(t):
    """Give the HH:MM:SS prefix of a run log line for the local time t."""
    return t.strftime("%H:%M:%S")


def apple_time(t):
    """Give the transcript time (seconds since 2001-01-01 UTC) of the local time t."""
    return (t.astimezone(dt.timezone.utc) - scan.APPLE_EPOCH).total_seconds()


def started_line(inst, t, number=1, limit=LIMIT):
    """Give the run log line that starts the agent on inst at the local time t."""
    return (f"{clock(t)} running the agent... instance={inst} number={number} of=16 "
            f"limit_seconds={limit} prompt=source-only-v1")


def write_log(path, lines, mtime):
    """Write a run log, and set its change time.

    - path: the log file.
    - lines: the lines of the log.
    - mtime: the local datetime of the last change of the file.
    """
    path.write_text("".join(line + "\n" for line in lines))
    stamp = mtime.timestamp()
    os.utime(path, (stamp, stamp))


def write_rows(path, rows):
    """Write rows to a JSON Lines file. Make the parent dirs first."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))


def running_line(op, tool="execute"):
    """Give the text line of one 'running' operation event of op."""
    return f"[{tool}] {tool} shell ({op}) running: stderr: ."


def running_row(op, seq, t, tool="execute", events=1):
    """Give a transcript row of 'running' operation events of op at the local time t.

    - events: the count of events in the row. Since Router ^zze1067, the
      journal merges consecutive progress events of one operation into one
      row, with one text line for each event.
    """
    return {"kind": "toolOutput", "seq": seq, "ts": apple_time(t),
            "text": "\n".join([running_line(op, tool)] * events),
            "entry": {"entryId": f"01ENTRY{seq:019d}", "toolName": tool, "segments": []}}


def completed_row(op, seq, t, tool="execute"):
    """Give a transcript row of the final 'completed' event of op at the local time t."""
    return {"kind": "toolOutput", "seq": seq, "ts": apple_time(t),
            "text": f'[{tool}] {tool} shell ({op}) completed: {{"exitCode":0}}',
            "entry": {"entryId": f"01ENTRY{seq:019d}", "toolName": tool, "segments": []}}


def write_transcript(transcripts, inst, rows):
    """Write the one transcript of inst in a kept transcripts dir."""
    write_rows(transcripts / inst / "01SESSION" / "transcript.jsonl", rows)


def notices(op, count, start, first_seq=1):
    """Give count 'running' rows of op, one second apart, from the local time start."""
    return [running_row(op, first_seq + i, start + dt.timedelta(seconds=i)) for i in range(count)]


def quiet(fn, *args):
    """Call fn with args. Give the text that it writes to stdout."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        fn(*args)
    return out.getvalue()


class ScanTestCase(unittest.TestCase):
    """A temporary bench dir, and a fresh result of the scan for each test."""

    def setUp(self):
        """Make the bench dir and the paths of the fake run in it."""
        self.tmp = tempfile.TemporaryDirectory()
        self.bench = Path(self.tmp.name) / "bench"
        self.bench.mkdir()
        self.log = self.bench / "run.x.log"
        self.preds = self.bench / "preds.x.jsonl"
        self.transcripts = self.bench / "preds.x.transcripts"
        self.R = scan.new_result()

    def tearDown(self):
        """Remove the bench dir."""
        self.tmp.cleanup()

    def scan_run(self):
        """Run the steps of the scan that read the log, the preds and the transcripts.

        Give the text of the steps, the check of the run and the progress.
        """
        steps = (lambda: scan.scan_log(str(self.log), LIMIT, self.R),
                 lambda: scan.scan_preds(str(self.preds), None, self.R),
                 lambda: scan.scan_transcripts([str(self.transcripts)], 60, self.R),
                 lambda: scan.check_same_run(self.R, str(self.preds)),
                 lambda: scan.progress(self.R, LIMIT))
        return "".join(quiet(step) for step in steps)

    def problem_texts(self):
        """Give the 'what' text of each problem that the scan found."""
        return [what for _, what, _ in self.R["problems"]]


class RunningNoticesCountOperations(ScanTestCase):
    """The 'running' notices are counted by operation, for each instance."""

    def test_the_count_gives_the_rows_and_the_unique_operations(self):
        """One operation writes many 'running' rows. A count of rows says
        nothing about how many operations ran, so the scan gives both."""
        write_transcript(self.transcripts, FIRST,
                         notices("01OPA", 3, OLD_START) + notices("01OPB", 1, OLD_START, first_seq=10))
        write_transcript(self.transcripts, SECOND, notices("01OPC", 2, OLD_START))
        quiet(scan.scan_transcripts, [str(self.transcripts)], 60, self.R)
        out = quiet(scan.report_tools, self.R)
        self.assertIn("'running' notices (not counted above): 6 rows from 3 operations", out)
        self.assertIn(f"{FIRST}=2/4", out)
        self.assertIn(f"{SECOND}=1/2", out)

    def test_the_final_event_of_an_operation_is_not_a_running_notice(self):
        """A 'completed' row ends an operation. It is not a notice, so it must
        not add to the rows or to the operations."""
        write_transcript(self.transcripts, FIRST,
                         notices("01OPA", 2, OLD_START) + [completed_row("01OPA", 5, OLD_START)])
        quiet(scan.scan_transcripts, [str(self.transcripts)], 60, self.R)
        out = quiet(scan.report_tools, self.R)
        self.assertIn("'running' notices (not counted above): 2 rows from 1 operations", out)

    def test_an_operation_with_more_rows_than_the_flood_limit_is_a_problem(self):
        """django__django-14667 wrote 13663 rows for one execute operation.
        The scan must name the instance and the operation."""
        write_transcript(self.transcripts, SECOND, notices("01FLOOD", scan.RUNNING_FLOOD + 1, OLD_START))
        quiet(scan.scan_transcripts, [str(self.transcripts)], 60, self.R)
        quiet(scan.problems, self.R)
        hits = [p for p in self.R["problems"] if SECOND in p[1]]
        self.assertEqual(len(hits), 1, self.problem_texts())
        self.assertIn(f"{scan.RUNNING_FLOOD + 1} 'running' rows", hits[0][1])
        self.assertIn("01FLOOD", hits[0][2])

    def test_an_operation_at_the_flood_limit_is_not_a_problem(self):
        """The limit itself is normal output. Only more rows than the limit is a flood."""
        write_transcript(self.transcripts, SECOND, notices("01EDGE", scan.RUNNING_FLOOD, OLD_START))
        quiet(scan.scan_transcripts, [str(self.transcripts)], 60, self.R)
        quiet(scan.problems, self.R)
        self.assertEqual([p for p in self.problem_texts() if "'running' rows" in p], [])

    def test_a_merged_row_of_many_events_is_one_row_and_no_flood(self):
        """Task ^p8c7snm: since Router ^zze1067, the journal writes the first
        progress event of an operation as its own row, and merges the next
        consecutive progress events into one row. A command that writes 10000
        single bytes thus gives a few rows. The scan must count the merged
        row as one row, and must not report a flood for it."""
        rows = [running_row("01MERGED", 1, OLD_START),
                running_row("01MERGED", 2, OLD_START, events=ONE_BYTE_WRITES),
                completed_row("01MERGED", 3, OLD_START)]
        write_transcript(self.transcripts, SECOND, rows)
        quiet(scan.scan_transcripts, [str(self.transcripts)], 60, self.R)
        quiet(scan.problems, self.R)
        self.assertEqual(self.R["tools"]["running"][SECOND]["01MERGED"], 2)
        self.assertEqual([p for p in self.problem_texts() if "'running' rows" in p], [])


class LogTimesTakeTheDayOfTheLog(ScanTestCase):
    """The HH:MM:SS times of a run log get the day of the log file, not today."""

    def test_an_old_log_starts_on_the_day_that_it_was_written(self):
        """The old log of 2026-10-05 must not start today. A wrong day makes
        each compare with a transcript time or a config change time wrong."""
        write_log(self.log, [started_line(FIRST, OLD_START)], OLD_START + WRITE_DELAY)
        self.assertEqual(scan.run_start(str(self.log)), OLD_START)

    def test_a_last_line_before_midnight_takes_the_day_before_the_change(self):
        """The file can change a few seconds after midnight, when the last
        line has a time before midnight. That line is of the day before."""
        late = dt.datetime(2026, 10, 5, 23, 59, 50)
        write_log(self.log, [started_line(FIRST, late)], late + WRITE_DELAY)
        self.assertEqual(scan.run_start(str(self.log)), late)


class AStoppedRunIsNotRunning(ScanTestCase):
    """An instance with no end line runs only when the run is live."""

    def test_an_old_log_shows_an_instance_with_no_end_as_stopped(self):
        """The old log has no end line for 13447 and no process writes it.
        The instance stopped; the scan must not compute its time against now."""
        write_log(self.log, [started_line(FIRST, OLD_START)], OLD_START + WRITE_DELAY)
        out = self.scan_run()
        self.assertIn("stopped (no end line)", out)
        self.assertNotIn("RUNNING", out)
        self.assertEqual([p for p in self.problem_texts() if "limit" in p], [])

    def test_a_live_log_shows_the_instance_near_its_limit(self):
        """A log that changed in the limit of its open instance is live. The
        output for a live run stays as it was."""
        now = dt.datetime.now().replace(microsecond=0)
        limit = 100
        start = now - dt.timedelta(seconds=95)
        write_log(self.log, [started_line(FIRST, start, limit=limit)], now)
        out = self.scan_run()
        self.assertIn("RUNNING", out)
        self.assertIn("NEAR THE LIMIT", out)
        self.assertTrue(any(FIRST in p and "limit" in p for p in self.problem_texts()), self.problem_texts())

    def test_a_process_that_writes_the_log_makes_an_old_log_live(self):
        """The harness can stay quiet for longer than the limit allows. A
        process that has the log open for write is the sure sign of a live run."""
        write_log(self.log, [started_line(FIRST, OLD_START)], OLD_START + WRITE_DELAY)
        self.assertTrue(scan.run_is_live(str(self.log), LIMIT, writers=["4242"]))

    def test_an_old_log_with_no_writer_is_not_live(self):
        """With no writer and no change in the limit of the open instance, the run stopped."""
        write_log(self.log, [started_line(FIRST, OLD_START)], OLD_START + WRITE_DELAY)
        self.assertFalse(scan.run_is_live(str(self.log), LIMIT, writers=[]))

    def test_lsof_output_gives_only_the_processes_that_write(self):
        """A reader (for example `tail -f`) does not make a run live; a writer does."""
        text = "p11\nf3\nar\np22\nf1\naw\np33\nf4\nau\n"
        self.assertEqual(scan.parse_writers(text), ["22", "33"])


class InputsOfDifferentRuns(ScanTestCase):
    """The scan warns when the log and the other inputs are of different runs."""

    def write_old_log(self, preds_name="bench/preds.x.jsonl"):
        """Write the stopped log of the old run: 13447 starts and has no end."""
        write_log(self.log, [
            f"{clock(OLD_START)} the instances of this run instances=16 to_do=16 predictions={preds_name}",
            started_line(FIRST, OLD_START)], OLD_START + WRITE_DELAY)

    def warnings(self, out):
        """Give the warning lines about different runs in out."""
        return [line for line in out.splitlines() if "different runs" in line]

    def test_a_transcript_that_starts_long_after_the_log_line_gives_a_warning(self):
        """The new run of the same NAME wrote the transcripts 488 s after the
        old log started the same instance. They are of another run."""
        self.write_old_log()
        write_transcript(self.transcripts, FIRST, notices("01OPA", 1, OLD_START + OTHER_RUN_DELAY))
        out = self.scan_run()
        self.assertTrue(self.warnings(out), out)
        self.assertTrue(any("different runs" in p for p in self.problem_texts()))

    def test_a_transcript_that_starts_before_the_log_line_gives_a_warning(self):
        """A transcript of the same run cannot start before the log starts its instance."""
        self.write_old_log()
        write_transcript(self.transcripts, FIRST, notices("01OPA", 1, OLD_START - dt.timedelta(days=1)))
        self.assertTrue(self.warnings(self.scan_run()))

    def test_a_transcript_of_the_same_run_gives_no_warning(self):
        """The transcript of the same run starts some seconds after the log line."""
        self.write_old_log()
        write_transcript(self.transcripts, FIRST, notices("01OPA", 1, OLD_START + SAME_RUN_DELAY))
        out = self.scan_run()
        self.assertEqual(self.warnings(out), [])

    def test_a_log_that_names_other_predictions_gives_a_warning(self):
        """The log names the predictions file of its run. Other predictions are of another run."""
        self.write_old_log(preds_name="bench/preds.other.jsonl")
        self.assertTrue(self.warnings(self.scan_run()))

    def test_a_prediction_for_an_instance_that_a_stopped_log_did_not_end_gives_a_warning(self):
        """A stopped run did not end 13447, so it did not write its prediction.
        A row for 13447 in the predictions comes from another run."""
        self.write_old_log()
        write_rows(self.preds, [{"instance_id": FIRST, "model_patch": "diff --git a/x b/x\n"}])
        self.assertTrue(self.warnings(self.scan_run()))


class AnUpstreamFixFromTheWebIsInformation(ScanTestCase):
    """The decision of 2026-10-07: an upstream fix that the agent finds on the
    web and uses is a valid result. The scan shows it, but not as a problem
    (task ^x2b83hh)."""

    # A web result of django__django-13447 that holds the upstream commit patch.
    UPSTREAM_ITEM = f"{FIRST} seq 7: From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001"

    def setUp(self):
        """Give the result of the scan one web result that looks like the upstream fix."""
        super().setUp()
        self.R["tools"]["upstream"].append(self.UPSTREAM_ITEM)

    def test_an_upstream_fix_is_not_a_ranked_problem(self):
        """The upstream fix shows how the agent solved an instance. It is not a problem."""
        quiet(scan.problems, self.R)
        self.assertEqual([p for p in self.problem_texts() if "upstream" in p], [])

    def test_the_tools_part_shows_the_upstream_fix(self):
        """The information stays in the TOOLS part, so a person can see it."""
        out = quiet(scan.report_tools, self.R)
        self.assertIn(f"== results that look like the upstream fix (web): 1 ['{self.UPSTREAM_ITEM}']", out)

    def test_no_output_says_that_the_score_does_not_measure_the_agent(self):
        """A score with web on is a valid score of the agent."""
        out = quiet(scan.report_tools, self.R) + quiet(scan.problems, self.R)
        self.assertNotIn("does not measure the agent", out)


if __name__ == "__main__":
    unittest.main()

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
import gc
import importlib.util
import io
import json
import os
import tempfile
import unittest
import warnings
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
# The scan reports a gap of this many seconds between two transcript lines as a stall.
STALL_GAP = 60


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


def call_row(seq, cid, tool, args):
    """Give the transcript row of one tool call of the model.

    - cid: the call id. The result row of the call has the same id.
    - args: the arguments of the call, as a dict.
    """
    return {"kind": "toolCalls", "seq": seq, "ts": apple_time(OLD_START),
            "entry": {"entryId": f"ENTRY-{seq}",
                      "toolCalls": [{"id": cid, "toolName": tool, "argumentsJSON": json.dumps(args)}]}}


def result_row(seq, cid, tool, text):
    """Give the transcript row of the result that the model got for the call cid."""
    return {"kind": "toolOutput", "seq": seq, "ts": apple_time(OLD_START),
            "entry": {"entryId": cid, "toolName": tool, "segments": [{"type": "text", "content": text}]}}


def model_call(seq, tool, args, text):
    """Give the call row and the result row of one tool call of the model, at seq and seq + 1."""
    cid = f"call_{seq:08d}"
    return [call_row(seq, cid, tool, args), result_row(seq + 1, cid, tool, text)]


def ulid(n):
    """Give a fake ULID (26 characters of the Crockford alphabet) that differs for each n."""
    return f"01M4{n:022d}"


def snippet(seq, code, detail):
    """Give the rows of one runCode call with the code, whose snippet result has the detail."""
    result = {"pending": False, "completionToken": ulid(seq), "outcome": "succeeded", "detail": detail}
    return model_call(seq, "runCode", {"code": code}, json.dumps(result))


def pending_notice(command_id):
    """Give the detail of an execute call: the notice that the command runs in the background."""
    return json.dumps(json.dumps({"pending": True, "completionToken": command_id,
                                  "next": "The command is running in the background, and this is not its result."}))


def pending_snippet(seq, code):
    """Give the rows of one runCode call with the code, whose snippet still runs in the background.

    The result is the notice of the snippet, not a snippet result. The
    transcript has no final operation event for its completion token.
    """
    result = {"pending": True, "completionToken": ulid(seq),
              "next": "The snippet is still running in the background, and this is not its result."}
    return model_call(seq, "runCode", {"code": code}, json.dumps(result))


def shell_lines(command_id, lines):
    """Give the detail of a getLines call that read the output lines of the command."""
    numbered = [f"{i}: {line}" for i, line in enumerate(lines, start=1)]
    return json.dumps({"commandID": command_id, "first": 1, "last": len(lines), "lines": numbered,
                       "status": "completed"})


def runtests_rows(seq, command_id, summary_lines):
    """Give the rows of a test run: an execute call of runtests.py, then the getLines call that reads its output."""
    start = snippet(seq, 'const r = await tools.shell.execute({ command: "python tests/runtests.py urls" });',
                    pending_notice(command_id))
    read = snippet(seq + 2, f'const r = await tools.shell.getLines({{ commandID: "{command_id}" }});',
                   shell_lines(command_id, ["E", "-" * 70] + summary_lines))
    return start + read


def edit(seq):
    """Give the rows of one files.edit call that the agent applied."""
    return snippet(seq, 'const r = await tools.files.edit({ path: "django/urls/resolvers.py", find: "a", replace: "b" });',
                   json.dumps({"applied": 1, "status": "applied"}))


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
                 self.scan_kept_transcripts,
                 lambda: scan.check_same_run(self.R, str(self.preds)),
                 lambda: scan.progress(self.R, LIMIT))
        return "".join(quiet(step) for step in steps)

    def scan_kept_transcripts(self):
        """Run the transcript step of the scan on the kept transcripts dir."""
        scan.scan_transcripts([str(self.transcripts)], STALL_GAP, self.R)

    def scan_rows(self, inst, rows):
        """Scan one transcript of inst with the rows.

        Give the output of the loop report and of the problems.
        """
        write_transcript(self.transcripts, inst, rows)
        quiet(self.scan_kept_transcripts)
        return quiet(scan.report_loops, self.R) + quiet(scan.problems, self.R)

    def problem_texts(self):
        """Give the 'what' text of each problem that the scan found."""
        return [what for _, what, _ in self.R["problems"]]

    def problems_with(self, *texts):
        """Give the problems whose 'what' text contains each of texts."""
        return [p for p in self.R["problems"] if all(text in p[1] for text in texts)]


class RunningNoticesCountOperations(ScanTestCase):
    """The 'running' notices are counted by operation, for each instance."""

    def test_the_count_gives_the_rows_and_the_unique_operations(self):
        """One operation writes many 'running' rows. A count of rows says
        nothing about how many operations ran, so the scan gives both."""
        write_transcript(self.transcripts, FIRST,
                         notices("01OPA", 3, OLD_START) + notices("01OPB", 1, OLD_START, first_seq=10))
        write_transcript(self.transcripts, SECOND, notices("01OPC", 2, OLD_START))
        quiet(self.scan_kept_transcripts)
        out = quiet(scan.report_tools, self.R)
        self.assertIn("'running' notices (not counted above): 6 rows from 3 operations", out)
        self.assertIn(f"{FIRST}=2/4", out)
        self.assertIn(f"{SECOND}=1/2", out)

    def test_the_final_event_of_an_operation_is_not_a_running_notice(self):
        """A 'completed' row ends an operation. It is not a notice, so it must
        not add to the rows or to the operations."""
        write_transcript(self.transcripts, FIRST,
                         notices("01OPA", 2, OLD_START) + [completed_row("01OPA", 5, OLD_START)])
        quiet(self.scan_kept_transcripts)
        out = quiet(scan.report_tools, self.R)
        self.assertIn("'running' notices (not counted above): 2 rows from 1 operations", out)

    def test_an_operation_with_more_rows_than_the_flood_limit_is_a_problem(self):
        """django__django-14667 wrote 13663 rows for one execute operation.
        The scan must name the instance and the operation."""
        self.scan_rows(SECOND, notices("01FLOOD", scan.RUNNING_FLOOD + 1, OLD_START))
        hits = self.problems_with(SECOND)
        self.assertEqual(len(hits), 1, self.problem_texts())
        self.assertIn(f"{scan.RUNNING_FLOOD + 1} 'running' rows", hits[0][1])
        self.assertIn("01FLOOD", hits[0][2])

    def test_an_operation_at_the_flood_limit_is_not_a_problem(self):
        """The limit itself is normal output. Only more rows than the limit is a flood."""
        self.scan_rows(SECOND, notices("01EDGE", scan.RUNNING_FLOOD, OLD_START))
        self.assertEqual(self.problems_with("'running' rows"), [])

    def test_a_merged_row_of_many_events_is_one_row_and_no_flood(self):
        """Task ^p8c7snm: since Router ^zze1067, the journal writes the first
        progress event of an operation as its own row, and merges the next
        consecutive progress events into one row. A command that writes 10000
        single bytes thus gives a few rows. The scan must count the merged
        row as one row, and must not report a flood for it."""
        rows = [running_row("01MERGED", 1, OLD_START),
                running_row("01MERGED", 2, OLD_START, events=ONE_BYTE_WRITES),
                completed_row("01MERGED", 3, OLD_START)]
        self.scan_rows(SECOND, rows)
        self.assertEqual(self.R["tools"]["running"][SECOND]["01MERGED"], 2)
        self.assertEqual(self.problems_with("'running' rows"), [])


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
        self.assertEqual(self.problems_with("limit"), [])

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
        self.assertTrue(self.problems_with(FIRST, "limit"), self.problem_texts())

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
        self.assertTrue(self.problems_with("different runs"))

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
        self.assertEqual(self.problems_with("upstream"), [])

    def test_the_tools_part_shows_the_upstream_fix(self):
        """The information stays in the TOOLS part, so a person can see it."""
        out = quiet(scan.report_tools, self.R)
        self.assertIn(f"== results that look like the upstream fix (web): 1 ['{self.UPSTREAM_ITEM}']", out)

    def test_no_output_says_that_the_score_does_not_measure_the_agent(self):
        """A score with web on is a valid score of the agent."""
        out = quiet(scan.report_tools, self.R) + quiet(scan.problems, self.R)
        self.assertNotIn("does not measure the agent", out)


class TheConfigStatesTheGitGroup(ScanTestCase):
    """The config part states `tools.git.enabled`, as it states the web group
    (task ^exkkyyr). A run with the git tools reads the git history of the
    clone, so a person must see if the run had them."""

    def config_text(self, yaml_text):
        """Write yaml_text as the agent config, and give the config part of the scan."""
        config = self.bench / "x.config.yaml"
        config.write_text(yaml_text)
        return quiet(scan.scan_config, str(config), self.R)

    def test_the_config_part_states_git_off(self):
        """`enabled: false` turns the git group off, and the scan says so."""
        out = self.config_text("tools:\n  git:\n    enabled: false\n")
        self.assertIn("tools.git.enabled = false", out)
        self.assertIs(self.R["git_enabled"], False)

    def test_the_config_part_states_git_on(self):
        """The bench config sets `enabled: true` so that the run states it."""
        out = self.config_text("tools:\n  git:\n    enabled: true\n")
        self.assertIn("tools.git.enabled = true", out)
        self.assertIs(self.R["git_enabled"], True)

    def test_a_config_with_no_git_entry_states_the_default(self):
        """A group that the config does not name is on by default."""
        out = self.config_text("tools:\n  web:\n    enabled: true\n")
        self.assertIn("tools.git.enabled = (not set: on by default)", out)
        self.assertIs(self.R["git_enabled"], True)

    def test_a_git_body_of_false_is_off(self):
        """The builtin config turns a group off with `false` as its whole body."""
        out = self.config_text("tools:\n  git: false\n")
        self.assertIn("tools.git.enabled = false", out)
        self.assertIn("groups that are off: git", out)


class RepeatedResultsAreALoop(ScanTestCase):
    """The scan counts the tool results that repeat an earlier result of the
    same instance (task ^8q8m1r4). Each call of such a loop succeeds, so the
    count of errors does not show it."""

    # The arguments and the result of the `list skill` loop of django__django-14667.
    LIST_SKILL = {"op": "list skill", "filter": "detected"}
    SKILL_TEXT = "- detected-projects: Discover project types, build commands, test commands."

    # The text of each problem about repeated results.
    REPEAT_TEXT = "repeat an earlier result"

    def skill_calls(self, count):
        """Give count `list skill` calls with the same result."""
        return [row for i in range(count) for row in model_call(10 * i, "skills", self.LIST_SKILL, self.SKILL_TEXT)]

    def test_eighteen_calls_with_the_same_result_are_a_loop(self):
        """18 calls with the same result give 17 repeats. The scan names the
        instance and the count, and the tool and the arguments of the group."""
        out = self.scan_rows(SECOND, self.skill_calls(18))
        hits = self.problems_with(self.REPEAT_TEXT)
        self.assertEqual(len(hits), 1, self.problem_texts())
        self.assertIn(SECOND, hits[0][1])
        self.assertIn("17 tool results repeat an earlier result", hits[0][1])
        self.assertIn('18 x skills {"filter": "detected", "op": "list skill"}', hits[0][2])
        self.assertIn(f"{SECOND}: 17 repeated results", out)

    def test_repeats_at_the_limit_are_not_a_loop(self):
        """A model can read the same thing again some times for a good reason.
        Only more repeats than REPEAT_LIMIT are a loop."""
        self.scan_rows(SECOND, self.skill_calls(scan.REPEAT_LIMIT + 1))
        self.assertEqual(self.problems_with(self.REPEAT_TEXT), [])

    def test_results_that_differ_only_in_a_ulid_are_the_same(self):
        """The getLines polling loop of django__django-13964: each poll of a
        running command gives no lines. The command id differs from command to
        command, but the model learns nothing new from each poll."""
        rows = []
        for i in range(18):
            rows += snippet(10 * i, f'tools.shell.getLines({{ commandID: "{ulid(i)}" }});',
                            json.dumps({"commandID": ulid(i), "first": 0, "last": 0, "lines": [], "status": "running"}))
        self.scan_rows(SECOND, rows)
        self.assertEqual(len(self.problems_with(self.REPEAT_TEXT)), 1, self.problem_texts())

    def test_a_call_with_many_lines_gives_one_report_line(self):
        """The code of a runCode call has newlines. On the run code-context-1008
        they moved the LOOP mark of django__django-14155 to a line of its own.
        The report gives each instance on one line, with its mark."""
        code = 'const r = await tools.shell.getLines({ commandID: "X" });\nreturn r;\n'
        rows = []
        for i in range(18):
            rows += snippet(10 * i, code, json.dumps({"lines": [], "status": "running"}))
        out = self.scan_rows(SECOND, rows)
        self.assertIn(f'{SECOND}: 17 repeated results; largest group 18 x runCode '
                      f'const r = await tools.shell.getLines({{ commandID: "X" }}); return r;  LOOP', out)

    def test_pending_notices_are_not_repeated_results(self):
        """Each execute call gives the notice that the command runs in the
        background. That notice is not a result, so it is not a repeat."""
        rows = []
        for i in range(18):
            rows += snippet(10 * i, f'tools.shell.execute({{ command: "ls {i}" }});', pending_notice(ulid(i)))
        self.scan_rows(SECOND, rows)
        self.assertEqual(self.problems_with(self.REPEAT_TEXT), [])

    def test_snippet_notices_with_no_final_result_are_not_repeated_results(self):
        """A runCode result can be the notice that the snippet still runs in
        the background. When the transcript has no final result for it, the
        model got no output. A notice is not a result, so 18 such notices are
        not a loop (review finding of 2026-10-08 on task ^8q8m1r4)."""
        rows = []
        for i in range(18):
            rows += pending_snippet(10 * i, f'tools.shell.execute({{ command: "ls {i}" }});')
        self.scan_rows(SECOND, rows)
        self.assertEqual(self.problems_with(self.REPEAT_TEXT), [])


class TheTestResultBeforeAndAfterTheLastEdit(ScanTestCase):
    """The scan compares the last test result before the last edit with the
    first test result after it (task ^8q8m1r4). In django__django-14155 both
    were `Ran 1 test in 0.000s FAILED (errors=1)`: the test did not load, and
    the edit did not change that."""

    NOT_LOADED = ["Ran 1 test in 0.000s", "", "FAILED (errors=1)"]
    # The text of each problem about a test result that the edit did not change.
    SAME_TEXT = "same before and after"

    def test_the_same_summary_before_and_after_the_edit_marks_the_instance(self):
        """The edit did not change what the test run says, so the instance is marked."""
        after = ["Ran 1 test in 0.001s", "", "FAILED (errors=1)"]
        out = self.scan_rows(FIRST, runtests_rows(10, ulid(1), self.NOT_LOADED) + edit(20)
                             + runtests_rows(30, ulid(2), after))
        self.assertIn(f"{FIRST}: before the last edit: Ran 1 test in 0.000s FAILED (errors=1); "
                      f"after it: Ran 1 test in 0.001s FAILED (errors=1)  SAME", out)
        self.assertEqual(len(self.problems_with(self.SAME_TEXT)), 1, self.problem_texts())

    def test_a_different_summary_after_the_edit_does_not_mark_the_instance(self):
        """The edit changed the result of the test run, so there is nothing to mark."""
        after = ["Ran 9 tests in 0.017s", "", "OK"]
        out = self.scan_rows(FIRST, runtests_rows(10, ulid(1), self.NOT_LOADED) + edit(20)
                             + runtests_rows(30, ulid(2), after))
        self.assertIn(f"{FIRST}: before the last edit: Ran 1 test in 0.000s FAILED (errors=1); "
                      f"after it: Ran 9 tests in 0.017s OK", out)
        self.assertNotIn("SAME", out)
        self.assertEqual(self.problems_with(self.SAME_TEXT), [])

    def test_a_read_of_runtests_py_is_not_a_test_run(self):
        """On the run code-context-1008 the model read tests/runtests.py with
        files.grep. The name of the test runner in the code of a call that is
        not a shell command does not make a test run, also when the result
        holds a summary line."""
        grep = snippet(10, 'const r = await tools.files.grep({ pattern: "Ran", path: "tests/runtests.py" });',
                       shell_lines(ulid(1), self.NOT_LOADED))
        out = self.scan_rows(FIRST, grep + edit(20) + runtests_rows(30, ulid(2), self.NOT_LOADED))
        self.assertIn(f"{FIRST}: before the last edit: no test run; "
                      f"after it: Ran 1 test in 0.000s FAILED (errors=1)", out)
        self.assertEqual(self.problems_with(self.SAME_TEXT), [])


class TheScoreReportIsClosedAfterTheRead(ScanTestCase):
    """On the run code-context-1008, `python3 -W error scan.py` wrote a
    ResourceWarning with a traceback: the scan did not close the score report."""

    def test_the_read_of_the_score_report_leaves_no_open_file(self):
        """Read a score report. No ResourceWarning is raised, also after a
        garbage collection."""
        report = Path(str(self.preds) + ".score.run1.json")
        report.write_text(json.dumps({"submitted": 2, "evaluated": 2, "resolved": 1, "unresolved": 1}))
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            out = quiet(scan.scan_score, str(self.preds), self.R)
            gc.collect()
        self.assertIn("score=1/2=50.0%", out)
        self.assertEqual([w for w in caught if issubclass(w.category, ResourceWarning)], [])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""test_report.py -- the proof that report.py compares the correct runs, and
finds the config of a run.

On 2026-10-06 report.py compared the 16-instance run `code-context-1006` with
the 2-instance check `recovery-check`, because it took the newest other score.
It also said "web config unknown" for a run whose name is not the name of its
config file. These tests hold the correct behaviour.

Each test writes fake run files into a temporary bench directory. The tests
need the standard library only:

    python3 -m unittest discover --start-directory .claude/skills/swebench-score/scripts
"""
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("swebench_report_script", HERE / "report.py")
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)

# The instances of the baseline run, and of a short check run.
SIXTEEN = [f"django__django-{n}" for n in range(13000, 13016)]
TWO = SIXTEEN[:2]
# The modification times of the fake score files, in seconds. A larger time
# is a newer score.
OLD, MIDDLE, NEW, NEWEST = 1_000_000, 2_000_000, 3_000_000, 4_000_000
# The config that the runs of these tests use, with web on, and with web off.
CONFIG_PATH = "bench/code-context.config.yaml"
WEB_ON_CONFIG = "tools:\n  web:\n    enabled: true\n"
WEB_OFF_CONFIG = "tools:\n  web:\n    enabled: false\n"


def write_rows(path, rows):
    """Write rows to a JSON Lines file.

    - path: the file to write.
    - rows: the dicts to write, one for each line.
    """
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))


def make_run(bench, name, ids, score_time, record=None):
    """Write the predictions, the record and one score report of a fake run.

    - bench: the bench directory.
    - name: the run NAME.
    - ids: the instance ids of the run. All of them are resolved.
    - score_time: the modification time of the score report.
    - record: the fields to add to each record row, or None.

    Give the path of the predictions file.
    """
    preds = bench / f"preds.{name}.jsonl"
    write_rows(preds, [{"instance_id": i, "model_patch": "diff --git a/x b/x\n"} for i in ids])
    write_rows(bench / f"preds.{name}.runs.jsonl", [{"instance_id": i, **(record or {})} for i in ids])
    score = bench / f"preds.{name}.jsonl.score.score_{name}.json"
    score.write_text(json.dumps({"run_id": f"score_{name}", "resolved_ids": ids,
                                 "unresolved_ids": [], "errored_ids": []}))
    os.utime(score, (score_time, score_time))
    return preds


def score_of(preds):
    """Give the path of the one score report of a fake run."""
    return Path(report.score_files(preds, report.repo_root(preds.parent))[-1])


def run_quiet(fn, *args):
    """Call fn with args, and keep what it writes to stdout and stderr.

    Give (the value of fn, the stderr text).
    """
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        value = fn(*args)
    return value, err.getvalue()


class BenchTestCase(unittest.TestCase):
    """A test with a temporary root directory that holds `bench/`."""

    def setUp(self):
        """Make the root and the bench directory of the test."""
        self.tmp = tempfile.TemporaryDirectory()
        # The report gives resolved paths. On macOS the temporary dir is below
        # /var, which is a link to /private/var, so resolve the root here too.
        self.root = Path(self.tmp.name).resolve()
        self.bench = self.root / "bench"
        self.bench.mkdir()

    def tearDown(self):
        """Remove the root of the test."""
        self.tmp.cleanup()


class TheRunToCompareWith(BenchTestCase):
    """Which other run the report compares with."""

    def test_it_takes_the_run_with_the_same_instances_and_not_a_newer_run_with_other_instances(self):
        """The bug of 2026-10-06: a newer 2-instance check is not a baseline.

        Two runs are comparable only when they have the same instances. The
        newest score of all is the check run, and the report must skip it.
        """
        same = make_run(self.bench, "baseline", SIXTEEN, OLD)
        make_run(self.bench, "check", TWO, NEWEST)
        this = make_run(self.bench, "now", SIXTEEN, NEW)
        target, _ = report.compare_target(None, this, str(self.bench), score_of(this))
        self.assertEqual(target, score_of(same))

    def test_it_takes_the_newest_of_the_runs_with_the_same_instances(self):
        """When two runs have the same instances, the newer one is the baseline."""
        make_run(self.bench, "older", SIXTEEN, OLD)
        newer = make_run(self.bench, "newer", SIXTEEN, MIDDLE)
        this = make_run(self.bench, "now", SIXTEEN, NEW)
        target, _ = report.compare_target(None, this, str(self.bench), score_of(this))
        self.assertEqual(target, score_of(newer))

    def test_it_says_which_run_it_took_and_why(self):
        """A person must see the baseline, and not guess it."""
        make_run(self.bench, "baseline", SIXTEEN, OLD)
        this = make_run(self.bench, "now", SIXTEEN, NEW)
        _, why = report.compare_target(None, this, str(self.bench), score_of(this))
        self.assertIn("same 16 instance ids", why)

    def test_it_takes_no_run_when_no_other_run_has_the_same_instances(self):
        """A comparison with other instances measures nothing, so give none."""
        make_run(self.bench, "check", TWO, OLD)
        this = make_run(self.bench, "now", SIXTEEN, NEW)
        target, why = report.compare_target(None, this, str(self.bench), score_of(this))
        self.assertIsNone(target)
        self.assertIn("--compare", why)

    def test_it_reads_the_instances_from_the_predictions_and_not_from_a_resumed_score(self):
        """A resumed score holds only the instances that it sent to docker.

        On 2026-10-06 the score of `code-context-1006` held 15 ids, because
        one instance had an empty patch. Its predictions held the same 16 ids
        as the baseline, so the two runs are comparable.
        """
        same = make_run(self.bench, "baseline", SIXTEEN, OLD)
        this = make_run(self.bench, "now", SIXTEEN, NEW)
        score_of(this).write_text(json.dumps({"resolved_ids": SIXTEEN[1:], "unresolved_ids": [],
                                              "errored_ids": []}))
        os.utime(score_of(this), (NEW, NEW))
        target, _ = report.compare_target(None, this, str(self.bench), score_of(this))
        self.assertEqual(target, score_of(same))

    def test_compare_name_takes_the_named_run_also_with_other_instances(self):
        """`--compare NAME` is the decision of a person, and the report obeys it."""
        check = make_run(self.bench, "check", TWO, OLD)
        make_run(self.bench, "baseline", SIXTEEN, MIDDLE)
        this = make_run(self.bench, "now", SIXTEEN, NEW)
        target, why = report.compare_target("check", this, str(self.bench), score_of(this))
        self.assertEqual(target, score_of(check))
        self.assertIn("--compare", why)


class TheConfigOfARun(BenchTestCase):
    """Which agent config a run used, and whether web was on."""

    def write_config(self, text):
        """Write the shared config of the runs of a test.

        - text: the YAML text of the config.
        """
        (self.root / CONFIG_PATH).write_text(text)

    def test_a_check_run_that_used_the_code_context_config_has_web_on(self):
        """The bug of 2026-10-06: `final-pass-check` gave "web config unknown".

        The run used `bench/code-context.config.yaml`, and its record names
        that file. The report must read the record, and not the run name.
        """
        self.write_config(WEB_ON_CONFIG)
        preds = make_run(self.bench, "x-check", TWO, OLD, record={"agent_config": CONFIG_PATH})
        config = report.config_of(preds, str(self.bench))
        self.assertEqual(config, self.root / CONFIG_PATH)
        self.assertEqual(report.web_state(config), "on")

    def test_the_record_gives_web_off_for_a_config_with_web_off(self):
        """The state comes from the file that the record names, not a constant."""
        self.write_config(WEB_OFF_CONFIG)
        preds = make_run(self.bench, "x-check", TWO, OLD, record={"agent_config": CONFIG_PATH})
        self.assertEqual(report.web_state(report.config_of(preds, str(self.bench))), "off")

    def test_the_run_log_gives_the_config_when_the_record_does_not(self):
        """A record from before the `agent_config` field has no config.

        The run log of `swebench_run.py` names the config in a line before
        the first instance starts.
        """
        self.write_config(WEB_ON_CONFIG)
        preds = make_run(self.bench, "x-check", TWO, OLD)
        (self.bench / "run.x-check.log").write_text(
            f"16:21:47 the agent config agent_config={CONFIG_PATH}\n"
            "16:22:37 running the agent... instance=a\n")
        self.assertEqual(report.config_of(preds, str(self.bench)), self.root / CONFIG_PATH)

    def test_the_run_log_gives_the_agent_config_argument(self):
        """A log that holds the command line gives `--agent-config PATH`."""
        self.write_config(WEB_ON_CONFIG)
        preds = make_run(self.bench, "x-check", TWO, OLD)
        (self.bench / "run.x-check.log").write_text(
            f"uv run bench/swebench_run.py bench/preds.x-check.jsonl --agent-config {CONFIG_PATH}\n")
        self.assertEqual(report.config_of(preds, str(self.bench)), self.root / CONFIG_PATH)

    def test_agent_output_in_the_run_log_does_not_name_the_config(self):
        """The agent can read a file that holds `--agent-config` text.

        Only the lines before the first instance starts come from the run
        script, so the report reads only those lines.
        """
        self.write_config(WEB_ON_CONFIG)
        preds = make_run(self.bench, "x-check", TWO, OLD)
        (self.bench / "run.x-check.log").write_text(
            "16:22:37 running the agent... instance=a\n"
            f"    the agent read: --agent-config {CONFIG_PATH}\n")
        self.assertIsNone(report.config_of(preds, str(self.bench)))

    def test_the_config_named_after_the_run_is_the_last_choice(self):
        """A run named `code-context` used `bench/code-context.config.yaml`."""
        self.write_config(WEB_ON_CONFIG)
        preds = make_run(self.bench, "code-context", TWO, OLD)
        self.assertEqual(report.config_of(preds, str(self.bench)), self.bench / "code-context.config.yaml")

    def test_a_run_with_no_config_found_has_web_unknown(self):
        """The report must not claim a web state that no file gives."""
        preds = make_run(self.bench, "x-check", TWO, OLD)
        config = report.config_of(preds, str(self.bench))
        self.assertIsNone(config)
        self.assertEqual(report.web_state(config), "unknown")

    def test_the_web_line_of_the_report_gives_the_config_of_the_run(self):
        """The WEB line is what a person reads, so it names the state and the file."""
        self.write_config(WEB_ON_CONFIG)
        preds = make_run(self.bench, "x-check", TWO, OLD, record={"agent_config": CONFIG_PATH})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            report.main([str(preds), "--bench", str(self.bench), "--root", str(self.root), "--no-compare"])
        web_line = next(line for line in out.getvalue().splitlines() if line.startswith("== WEB"))
        self.assertIn("config on", web_line)
        self.assertIn(str(self.root / CONFIG_PATH), web_line)


class AnUpstreamFixFromTheWebIsInformation(BenchTestCase):
    """The decision of 2026-10-07: an upstream fix that the agent finds on the
    web and uses is a valid result. The report shows the web state and the
    upstream fix as information, and the score stays valid (task ^x2b83hh)."""

    # The instance whose web result holds the upstream fix.
    WITH_FIX = TWO[0]
    # The line of a saved scan.py output that names the upstream fix of WITH_FIX.
    SCAN_LINE = (f"== results that look like the upstream fix (web): 1 "
                 f"['{WITH_FIX} seq 7: From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001']\n")

    def report_text(self, *argv):
        """Give the stdout of the report of the run `now` with web on, and with argv added."""
        (self.root / CONFIG_PATH).write_text(WEB_ON_CONFIG)
        make_run(self.bench, "now", TWO, NEW, record={"agent_config": CONFIG_PATH})
        scan_out = self.bench / "scan.now.txt"
        scan_out.write_text(self.SCAN_LINE)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            report.main(["now", "--bench", str(self.bench), "--root", str(self.root),
                         "--scan", str(scan_out), *argv])
        return out.getvalue()

    def test_web_on_gives_no_warning(self):
        """A score with web on is a valid score, so the report gives no WARNING."""
        self.assertNotIn("WARNING", self.report_text("--no-compare"))

    def test_no_line_says_that_the_score_does_not_measure_the_agent(self):
        """The old text said that a score with web on does not measure the agent alone."""
        out = self.report_text("--no-compare")
        self.assertNotIn("does not measure", out)
        self.assertNotIn("without an upstream fix", out)

    def test_the_table_and_the_web_part_show_the_upstream_fix(self):
        """The upstream-fix column and the WEB part keep the information."""
        out = self.report_text("--no-compare")
        row = next(line for line in out.splitlines() if line.strip().startswith(self.WITH_FIX))
        self.assertIn("YES", row)
        self.assertIn(f"upstream fix seen: {self.WITH_FIX}", out)

    def test_a_compare_with_web_off_is_a_compare_of_two_configurations(self):
        """A run with web on and a run with web off use different tools."""
        make_run(self.bench, "baseline", TWO, OLD, record={"agent_config": "bench/off.config.yaml"})
        (self.bench / "off.config.yaml").write_text(WEB_OFF_CONFIG)
        out = self.report_text()
        self.assertNotIn("WARNING", out)
        self.assertNotIn("do not measure", out)
        self.assertIn("two configurations", out)


class PathsStayInsideTheRepo(BenchTestCase):
    """Each path from input must resolve to a place inside the repo root.

    The repo root is the dir that holds `bench/`. The report refuses a path
    from the command line with an error. It skips a path from a run file with
    a note on stderr.
    """

    # The text of each refusal and each note.
    OUTSIDE = "outside the repo root"

    def setUp(self):
        """Make the repo root, and a second dir that is outside of it."""
        super().setUp()
        self.out_tmp = tempfile.TemporaryDirectory()
        self.outside = Path(self.out_tmp.name).resolve()

    def tearDown(self):
        """Remove the two dirs of the test."""
        self.out_tmp.cleanup()
        super().tearDown()

    def config_with_record(self, agent_config):
        """Give (config_of, stderr) for a run whose record names agent_config."""
        preds = make_run(self.bench, "x-check", TWO, OLD, record={"agent_config": agent_config})
        return run_quiet(report.config_of, preds, str(self.bench))

    def test_a_record_config_with_dot_dot_is_refused(self):
        """`../../etc/passwd` in the record must not be read."""
        config, err = self.config_with_record("../../etc/passwd")
        self.assertIsNone(config)
        self.assertIn(self.OUTSIDE, err)

    def test_a_record_config_with_an_absolute_path_outside_the_repo_is_refused(self):
        """An absolute path outside the repo must not be read, also when the file exists."""
        outside_config = self.outside / "code-context.config.yaml"
        outside_config.write_text(WEB_ON_CONFIG)
        config, err = self.config_with_record(str(outside_config))
        self.assertIsNone(config)
        self.assertIn(self.OUTSIDE, err)

    def test_a_record_config_inside_the_repo_is_accepted(self):
        """The normal record value, relative or absolute, gives the config file."""
        (self.root / CONFIG_PATH).write_text(WEB_ON_CONFIG)
        for value in (CONFIG_PATH, str(self.root / CONFIG_PATH)):
            with self.subTest(agent_config=value):
                config, err = self.config_with_record(value)
                self.assertEqual(config, self.root / CONFIG_PATH)
                self.assertEqual(err, "")

    def test_a_run_log_config_outside_the_repo_is_refused(self):
        """The run log is input too, so its config path gets the same check."""
        preds = make_run(self.bench, "x-check", TWO, OLD)
        (self.bench / "run.x-check.log").write_text("16:21:47 the agent config agent_config=../../etc/passwd\n")
        config, err = run_quiet(report.config_of, preds, str(self.bench))
        self.assertIsNone(config)
        self.assertIn(self.OUTSIDE, err)

    def test_a_command_line_path_outside_the_repo_is_refused_with_an_error(self):
        """Each path argument gets the check, and the report stops with exit code 2."""
        make_run(self.bench, "now", SIXTEEN, NEW)
        outside_file = self.outside / "preds.evil.jsonl.score.x.json"
        outside_file.write_text("{}")
        bench = ["--bench", str(self.bench), "--root", str(self.root)]
        cases = {
            # bench/preds.{NAME}.jsonl: the first `..` joins `preds.`, and
            # the next three go up from bench/ to the parent of the repo root.
            "run": ["../../../../etc/x", *bench],
            "--score": ["--score", str(outside_file), *bench],
            "--scan": ["now", "--scan", str(outside_file), *bench],
            "--compare": ["now", "--compare", str(outside_file), *bench],
            "--root": ["now", "--bench", str(self.bench), "--root", str(self.outside)],
        }
        for what, argv in cases.items():
            with self.subTest(argument=what):
                code, err = run_quiet(report.main, argv)
                self.assertEqual(code, 2)
                self.assertIn(self.OUTSIDE, err)

    def test_beside_refuses_a_predictions_path_outside_the_repo(self):
        """The record and the transcripts stand beside the predictions file."""
        with self.assertRaisesRegex(report.OutsideRoot, self.OUTSIDE):
            report.beside(self.outside / "preds.x.jsonl", ".runs.jsonl", self.root)

    def test_preds_of_score_refuses_a_score_outside_the_repo(self):
        """The predictions path of a score is the score path less its suffix."""
        with self.assertRaisesRegex(report.OutsideRoot, self.OUTSIDE):
            report.preds_of_score(self.bench / "../../x/preds.y.jsonl.score.z.json", self.root)

    def test_a_score_file_link_that_leaves_the_repo_is_skipped(self):
        """A score file name in bench/ can be a link to a file outside the repo."""
        preds = make_run(self.bench, "now", SIXTEEN, NEW)
        outside_score = self.outside / "evil.json"
        outside_score.write_text("{}")
        (self.bench / "preds.now.jsonl.score.evil.json").symlink_to(outside_score)
        files, err = run_quiet(report.score_files, preds, self.root)
        self.assertEqual([Path(f).name for f in files], ["preds.now.jsonl.score.score_now.json"])
        self.assertIn(self.OUTSIDE, err)

    def test_a_predictions_link_that_leaves_the_repo_is_skipped(self):
        """A predictions file name in bench/ can be a link to a file outside the repo."""
        make_run(self.bench, "now", SIXTEEN, NEW)
        outside_preds = self.outside / "preds.evil.jsonl"
        outside_preds.write_text("")
        (self.bench / "preds.evil.jsonl").symlink_to(outside_preds)
        files, err = run_quiet(report.all_preds, str(self.bench))
        self.assertEqual([f.name for f in files], ["preds.now.jsonl"])
        self.assertIn(self.OUTSIDE, err)

    def test_a_transcript_link_that_leaves_the_repo_is_skipped(self):
        """A transcript in the kept transcripts dir can be a link to a file outside the repo."""
        transcripts = self.bench / "preds.now.transcripts"
        (transcripts / "a").mkdir(parents=True)
        outside_transcript = self.outside / "transcript.jsonl"
        outside_transcript.write_text("")
        (transcripts / "a" / "transcript.jsonl").symlink_to(outside_transcript)
        web, err = run_quiet(report.web_use, str(transcripts), self.root)
        self.assertEqual(web, {})
        self.assertIn(self.OUTSIDE, err)

    def test_harness_detail_refuses_a_run_id_that_leaves_the_harness_logs(self):
        """The run id and the instance id come from the score report, which is input.

        --root is inside the repo root, and the harness logs are below it, so
        a path inside the harness logs is also inside the repo root. The two
        temporary dirs have the same parent, so the second instance id names
        a dir that exists, and glob finds it.
        """
        escape = f"../../../../../{self.outside.name}"
        for run_id, iid in (("../../../../etc", "passwd"), ("score_now", escape)):
            with self.subTest(run_id=run_id, iid=iid):
                (self.root / report.LOGS_DIR / "score_now" / "model").mkdir(parents=True, exist_ok=True)
                detail = report.harness_detail(str(self.root), run_id, iid)
                self.assertIn("outside the harness logs dir", detail)


if __name__ == "__main__":
    unittest.main()

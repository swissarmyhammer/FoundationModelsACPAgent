#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_live_score.py -- the proof that a run scores each instance when
it ends, and not at the end of the run.

`swebench_run.py` made the patches, and a person ran `swebench_score.py` after
the run. A run of 24 instances takes most of a day, so the first score came a
day after the first patch. There is no good reason to wait: the score of one
instance needs its row in the predictions file and nothing else.

So the run gives each instance with a patch to a queue, and ONE worker scores
the queue in the background, one instance at a time. The emulated x86 docker
containers need much memory, and the machine holds the model of the agent too.
`swebench_live_score.py` holds that queue.

These tests hold six rules:

  * The names of the score come from the predictions file:
    `bench/preds.flint24.jsonl` -> run id `score_flint24`, and the output of
    each score goes to `bench/score.flint24.log`.
  * Each score is ONE call of `swebench_score.py` with ONE instance id and the
    run id of the run, so the reports of the run add up into one report.
  * A queued instance does not wait for its score: the queue answers at once.
  * Each score writes one line with the result of the instance and the
    running total of the run.
  * A score that fails writes one line with its exit code, and the queue goes
    on with the next instance.
  * A run that continues queues each instance that has no report yet.

No test here starts docker or `uv`. Each test gives the queue a stand-in for
`subprocess.run`, and that stand-in writes the report the harness would write.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_live_score.py
    python3 bench/test_swebench_live_score.py
"""
import json
import tempfile
import threading
import unittest
from pathlib import Path

from swebench_live_score import (
    LiveScore,
    score_command,
    score_log_path,
    score_run_id,
)
from test_fixtures import COMMAND_FAILED, a_runner

# The predictions file of a run with a name, as the bench skill starts one.
A_NAMED_PREDICTIONS = Path("bench/preds.flint24.jsonl")
# Two instances of SWE-bench_Lite: the first one is resolved, and the second
# one is not.
RESOLVED_ID = "django__django-13447"
UNRESOLVED_ID = "psf__requests-2317"
# The name of the model in each prediction row. The harness puts the report of
# an instance in a directory with this name.
A_MODEL = "acp-agent"
# The exit code of `swebench_score.py` when the harness raised an error that is
# not a docker failure.
HARNESS_ERROR_EXIT = 5
# What a score writes, and what the score log held before it.
A_SCORE_OUTPUT = "the score: resolved of evaluated resolved=1 evaluated=1\n"
AN_EARLIER_SCORE_OUTPUT = "the score of an earlier instance\n"
# How long a test waits for the worker before it calls the queue broken. A
# queue that works answers in much less than one second.
WAIT_SECONDS = 5


def a_report(evaluation_root, run_id, instance_id, *, resolved):
    """Write the report.json of one instance, as the harness writes it.

    - evaluation_root: the `logs/run_evaluation` directory of the test.
    - run_id: the run id of the score.
    - instance_id: the instance that the report is about.
    - resolved: whether the patch resolved the instance.
    """
    report = evaluation_root / run_id / A_MODEL / instance_id / "report.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({instance_id: {"resolved": resolved}}))


def a_scoring_runner(evaluation_root, resolved_ids, **answer):
    """A stand-in for `subprocess.run` that scores as the harness does.

    - evaluation_root: the `logs/run_evaluation` directory of the test.
    - resolved_ids: the instances whose patch the stand-in resolves.
    - answer: what each call gives, for example `returncode`.

    The stand-in reads the instance id and the run id from the command, and
    it writes the report of that instance before it answers. As the harness
    does, it does NOT score an instance that has a report under the run id
    already. It keeps each call in `calls`, as the stand-in of
    `test_fixtures.py` does.
    """
    answers = a_runner(**answer)

    def run(command, **keywords):
        instance_id = command[command.index("--instance-ids") + 1]
        run_id = command[command.index("--run-id") + 1]
        if not list((evaluation_root / run_id).glob(f"*/{instance_id}/*")):
            a_report(
                evaluation_root,
                run_id,
                instance_id,
                resolved=instance_id in resolved_ids,
            )
        return answers(command, **keywords)

    run.calls = answers.calls
    return run


class Lines:
    """A stand-in for `log` that keeps each line it gets.

    Each line is a pair of the message and its fields, so a test reads the
    fields by their names and not from a sentence.
    """

    def __init__(self):
        self.lines = []

    def __call__(self, message, **fields):
        self.lines.append((message, fields))

    def fields_of(self, word):
        """The fields of each line whose message holds the given word."""
        return [fields for message, fields in self.lines if word in message]


class TestScoreNames(unittest.TestCase):
    """The run id and the log of the score come from the predictions file."""

    def test_the_run_id_is_the_name_of_the_predictions(self):
        """A run of `preds.flint24.jsonl` scores into `score_flint24`. One
        run id for the whole run is what makes the reports add up into one
        report, and the name says which run the report is about."""
        self.assertEqual(score_run_id(A_NAMED_PREDICTIONS), "score_flint24")

    def test_the_log_of_the_score_stands_beside_the_predictions(self):
        """The output of docker goes to `bench/score.flint24.log`, and not
        into the log of the run, where it would hide the lines of the
        agent."""
        self.assertEqual(
            score_log_path(A_NAMED_PREDICTIONS), Path("bench/score.flint24.log")
        )

    def test_the_command_scores_one_instance_with_the_run_id(self):
        """The score of one instance is one call of `swebench_score.py`, with
        that one id and the run id of the run. The script reads every report
        of the run id, so each call writes the report of the run so far."""
        command = score_command(A_NAMED_PREDICTIONS, RESOLVED_ID)
        self.assertEqual(
            command[-5:],
            [
                str(A_NAMED_PREDICTIONS),
                "--instance-ids",
                RESOLVED_ID,
                "--run-id",
                "score_flint24",
            ],
        )


class TestLiveScore(unittest.TestCase):
    """The queue scores each instance in the background, one at a time."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        root = Path(self.folder.name)
        self.predictions = root / "preds.flint24.jsonl"
        self.evaluation_root = root / "logs" / "run_evaluation"
        self.lines = Lines()

    def a_live_score(self, runner):
        """The queue of the test, with the given stand-in for the command."""
        return LiveScore(
            self.predictions,
            self.lines,
            runner=runner,
            evaluation_root=self.evaluation_root,
        )

    def test_a_score_says_whether_the_instance_is_resolved(self):
        """The line of a score names the instance and says yes or no, so a
        person who watches the run sees each result as it comes."""
        live = self.a_live_score(
            a_scoring_runner(self.evaluation_root, {RESOLVED_ID})
        )
        live.queue(RESOLVED_ID)
        live.drain()
        self.assertEqual(
            self.lines.fields_of("scored")[0]["resolved"], "yes"
        )

    def test_a_new_patch_is_scored_in_place_of_an_old_report(self):
        """The harness skips an instance that has a report under the run id.
        A run with `--force` makes a new patch for each instance, and its
        score must be the score of that patch, and not of the old one."""
        a_report(
            self.evaluation_root,
            score_run_id(self.predictions),
            RESOLVED_ID,
            resolved=False,
        )
        live = self.a_live_score(
            a_scoring_runner(self.evaluation_root, {RESOLVED_ID})
        )
        live.queue(RESOLVED_ID)
        live.drain()
        self.assertEqual(
            self.lines.fields_of("scored")[0]["resolved"], "yes"
        )

    def test_a_score_gives_the_running_total_of_the_run(self):
        """Each line of a score carries the total so far, resolved of scored,
        so the last line of a run log is the score of the run."""
        live = self.a_live_score(
            a_scoring_runner(self.evaluation_root, {RESOLVED_ID})
        )
        live.queue(RESOLVED_ID)
        live.queue(UNRESOLVED_ID)
        live.drain()
        last = self.lines.fields_of("scored")[-1]
        self.assertEqual((last["total_resolved"], last["total_scored"]), (1, 2))

    def test_drain_gives_the_totals_of_the_run(self):
        """The summary table of the run shows the live score, and it waits
        for the queue to give the total of every instance."""
        live = self.a_live_score(
            a_scoring_runner(self.evaluation_root, {RESOLVED_ID})
        )
        live.queue(RESOLVED_ID)
        live.queue(UNRESOLVED_ID)
        self.assertEqual(live.drain(), (1, 2))

    def test_the_output_of_a_score_goes_to_the_score_log(self):
        """The docker output of a score is long, so it goes to the score log
        beside the predictions, and the log of the run keeps one line. The
        log is APPENDED, so the output of the scores before stays."""
        score_log = score_log_path(self.predictions)
        score_log.write_text(AN_EARLIER_SCORE_OUTPUT)
        scoring = a_scoring_runner(self.evaluation_root, {RESOLVED_ID})

        def writing(command, **keywords):
            keywords["stdout"].write(A_SCORE_OUTPUT)
            return scoring(command, **keywords)

        live = self.a_live_score(writing)
        live.queue(RESOLVED_ID)
        live.drain()
        self.assertEqual(
            score_log.read_text(), AN_EARLIER_SCORE_OUTPUT + A_SCORE_OUTPUT
        )

    def test_a_queued_instance_does_not_wait_for_its_score(self):
        """The agent loop must not wait for docker. The stand-in holds the
        score until the test lets it go, and the queue answers before that."""
        let_go = threading.Event()
        scoring = a_scoring_runner(self.evaluation_root, {RESOLVED_ID})

        def held(command, **keywords):
            let_go.wait(WAIT_SECONDS)
            return scoring(command, **keywords)

        live = self.a_live_score(held)
        live.queue(RESOLVED_ID)
        answered_first = not let_go.is_set()
        let_go.set()
        live.drain()
        self.assertTrue(answered_first)

    def test_one_instance_is_scored_at_a_time(self):
        """Two emulated docker containers can use all the memory of the
        machine, beside the model. So no score starts before the last one
        ended."""
        scoring = a_scoring_runner(self.evaluation_root, {RESOLVED_ID})
        running = []
        most = []

        def counted(command, **keywords):
            running.append(command)
            most.append(len(running))
            answer = scoring(command, **keywords)
            running.pop()
            return answer

        live = self.a_live_score(counted)
        live.queue(RESOLVED_ID)
        live.queue(UNRESOLVED_ID)
        live.drain()
        self.assertEqual(max(most), 1)

    def test_a_failed_score_names_its_exit_code(self):
        """A score that fails writes its exit code, so a person knows which
        failure of `swebench_score.py` it was."""
        live = self.a_live_score(
            a_scoring_runner(
                self.evaluation_root, set(), returncode=HARNESS_ERROR_EXIT
            )
        )
        live.queue(RESOLVED_ID)
        live.drain()
        self.assertEqual(
            self.lines.fields_of("failed")[0]["exit_code"], HARNESS_ERROR_EXIT
        )

    def test_a_failed_score_does_not_stop_the_queue(self):
        """A failure of docker for one instance is not a reason to lose the
        score of the next one."""
        runner = a_runner(returncode=COMMAND_FAILED)
        live = self.a_live_score(runner)
        live.queue(RESOLVED_ID)
        live.queue(UNRESOLVED_ID)
        live.drain()
        self.assertEqual(len(runner.calls), 2)

    def test_a_command_that_cannot_start_does_not_stop_the_run(self):
        """`uv` can be absent from the PATH. The run must go on, and the line
        of the failure names the error."""
        live = self.a_live_score(a_runner(raises=FileNotFoundError("uv")))
        live.queue(RESOLVED_ID)
        live.drain()
        self.assertIn("uv", str(self.lines.fields_of("failed")[0]["error"]))

    def test_a_continued_run_queues_an_instance_with_no_report(self):
        """A run that stopped can have patches that were never scored. The
        run that continues it scores them."""
        runner = a_scoring_runner(self.evaluation_root, {RESOLVED_ID})
        live = self.a_live_score(runner)
        live.catch_up(RESOLVED_ID)
        live.drain()
        self.assertEqual(len(runner.calls), 1)

    def test_a_continued_run_does_not_score_an_instance_again(self):
        """An instance that has its report under the run id has its score,
        and docker is slow. So the run that continues does not score it
        again."""
        a_report(
            self.evaluation_root,
            score_run_id(self.predictions),
            RESOLVED_ID,
            resolved=True,
        )
        runner = a_scoring_runner(self.evaluation_root, {RESOLVED_ID})
        live = self.a_live_score(runner)
        live.catch_up(RESOLVED_ID)
        live.drain()
        self.assertEqual(runner.calls, [])


if __name__ == "__main__":
    unittest.main()

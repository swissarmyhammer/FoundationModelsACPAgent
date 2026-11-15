"""
swebench_live_score.py -- score each instance of a run when it ends.

`swebench_run.py` made the patches, and a person ran `swebench_score.py` after
the run. A run of 24 instances takes most of a day, so the first score came a
day after the first patch. There is no good reason to wait: the score of one
instance needs its row in the predictions file and nothing else.

So the run gives each instance with a patch to a queue, and ONE worker thread
scores the queue in the background:

    uv run bench/swebench_score.py bench/preds.flint24.jsonl \\
        --instance-ids django__django-13447 --run-id score_flint24

The worker scores ONE instance at a time. docker emulates the x86_64 image of
an instance on Apple Silicon, an emulated container needs much memory, and
the machine holds the model of the agent too.

Each call has the SAME run id. `swebench_score.py` reads every report.json of
that run id, so each call writes the report of the run so far beside the
predictions, and the last call writes the report of the whole run. The output
of docker is long, so it goes to `score.<NAME>.log` beside the predictions,
and the log of the run keeps one line for each score.

The command gets the environment of the run. A run that scores headless sets
`DOCKER_CONFIG` to a docker config with no `credsStore`, because the keychain
does not answer there, and the score thus gets that config.

An empty patch is not scored, and an instance that failed has no patch: the
score counts both as not resolved. A score that fails writes one line with
its exit code, and the run goes on.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block
of a module that the script imports. This module needs the standard library
only, so its tests need no package. The run gives it the `log` of
`swebench_common.py`.
"""
import json
import queue
import shutil
import subprocess
import threading
from pathlib import Path
from typing import NamedTuple

# The script that scores, beside this module.
SCORE_SCRIPT = Path(__file__).resolve().parent / "swebench_score.py"
# Where the harness writes the report of each instance, below the directory
# the score runs in: `<root>/<run id>/<model>/<instance id>/report.json`.
EVALUATION_ROOT = Path("logs/run_evaluation")
REPORT_NAME = "report.json"
# The predictions file of a named run is `preds.<NAME>.jsonl`. NAME names the
# run id of the score and its log.
PREDICTIONS_PREFIX = "preds."
RUN_ID_PREFIX = "score_"
SCORE_LOG_SHAPE = "score.{name}.log"
# The exit code of a command that did its work.
COMMAND_DID_ITS_WORK = 0
# What the line of a score says about the instance.
YES = "yes"
NO = "no"
# What the worker takes from the queue when the run has no more instances.
STOP = None


class Totals(NamedTuple):
    """The live score of a run so far.

    - resolved: how many scored instances the patch resolved.
    - scored: how many instances have a report under the run id.
    """
    resolved: int
    scored: int


def score_name(predictions):
    """The NAME of a run: `bench/preds.flint24.jsonl` -> `flint24`.

    - predictions: the predictions file of the run.

    A file that is not named `preds.<NAME>.jsonl` gives its whole stem.
    """
    stem = Path(predictions).stem
    if stem.startswith(PREDICTIONS_PREFIX):
        return stem[len(PREDICTIONS_PREFIX):]
    return stem


def score_run_id(predictions):
    """The one run id of the scores of a run: `score_<NAME>`.

    - predictions: the predictions file of the run.
    """
    return RUN_ID_PREFIX + score_name(predictions)


def score_log_path(predictions):
    """The file that keeps the output of each score, beside the predictions.

    - predictions: the predictions file of the run.
    """
    predictions = Path(predictions)
    return predictions.parent / SCORE_LOG_SHAPE.format(
        name=score_name(predictions)
    )


def score_command(predictions, instance_id):
    """The command that scores one instance into the run id of the run.

    - predictions: the predictions file of the run.
    - instance_id: the instance to score.
    """
    return [
        "uv", "run", str(SCORE_SCRIPT), str(predictions),
        "--instance-ids", instance_id,
        "--run-id", score_run_id(predictions),
    ]


def tally_reports(run_root):
    """Read the report.json files below the directory of one run id.

    - run_root: `logs/run_evaluation/<run id>`.

    Returns (resolved_ids, evaluated_ids). A report that cannot be read, or
    that is empty, counts for nothing. This is safe while the harness writes,
    and it is safe if a second try writes over a report with a new result.
    """
    resolved, evaluated = set(), set()
    for rep in Path(run_root).glob(f"*/*/{REPORT_NAME}"):
        try:
            d = json.loads(rep.read_text())
        except (OSError, ValueError):
            continue
        if not d:
            continue
        k = next(iter(d))
        evaluated.add(k)
        if d[k].get("resolved"):
            resolved.add(k)
    return resolved, evaluated


class LiveScore:
    """The queue of the scores of one run, and its one worker thread.

    - predictions: the predictions file of the run.
    - log: what writes one milestone line, as `swebench_common.log` does.
    - runner: what runs the command, as `subprocess.run` does.
    - evaluation_root: where the harness writes its reports.

    The worker is a daemon thread, so a run that stops with `Ctrl-C` does not
    wait for docker.
    """

    def __init__(
        self,
        predictions,
        log,
        *,
        runner=subprocess.run,
        evaluation_root=EVALUATION_ROOT,
    ):
        self.predictions = Path(predictions)
        self.log = log
        self.runner = runner
        self.run_root = Path(evaluation_root) / score_run_id(predictions)
        self.waiting = queue.Queue()
        self.worker = threading.Thread(target=self.work, daemon=True)
        self.worker.start()

    def queue(self, instance_id):
        """Give one instance to the worker, and return at once.

        - instance_id: an instance whose row with a patch is on disk.
        """
        self.waiting.put(instance_id)
        self.log(
            "[dim]queued for the live score[/]",
            instance=instance_id,
            waiting=self.waiting.qsize(),
        )

    def catch_up(self, instance_id):
        """Queue an instance of an earlier run that has no report yet.

        - instance_id: an instance whose row with a patch is on disk.

        An instance with a report has its score, and docker is slow.
        """
        if self.report_of(instance_id) is None:
            self.queue(instance_id)

    def drain(self):
        """Wait until the worker scored every queued instance, and stop it.

        Returns the `Totals` of the run id.
        """
        self.log(
            "waiting for the live score to end", waiting=self.waiting.qsize()
        )
        self.waiting.put(STOP)
        self.worker.join()
        return self.totals()

    def totals(self):
        """The `Totals` of every report under the run id."""
        resolved, evaluated = tally_reports(self.run_root)
        return Totals(resolved=len(resolved), scored=len(evaluated))

    def report_of(self, instance_id):
        """The report.json of one instance under the run id, or None.

        - instance_id: the instance.
        """
        found = sorted(self.run_root.glob(f"*/{instance_id}/{REPORT_NAME}"))
        return found[0] if found else None

    def forget(self, instance_id):
        """Remove the old score of one instance under the run id.

        - instance_id: the instance that has a new patch.

        The harness skips an instance that has a report under the run id. A
        run with `--force` makes a new patch for each instance, and an old
        report would give the score of the old patch.
        """
        for old in self.run_root.glob(f"*/{instance_id}"):
            shutil.rmtree(old, ignore_errors=True)

    def work(self):
        """Score each instance of the queue, one at a time, until `STOP`."""
        for instance_id in iter(self.waiting.get, STOP):
            self.score(instance_id)

    def score(self, instance_id):
        """Score one instance, and write the line of its result.

        - instance_id: the instance to score.

        No failure leaves this method, because a failed score must never stop
        the run.
        """
        self.forget(instance_id)
        command = score_command(self.predictions, instance_id)
        try:
            with score_log_path(self.predictions).open("a") as output:
                answer = self.runner(
                    command, stdout=output, stderr=subprocess.STDOUT
                )
        except (OSError, subprocess.SubprocessError) as error:
            self.log(
                "[red]live score failed[/] -- the run goes on",
                instance=instance_id,
                error=error,
            )
            return
        if answer.returncode != COMMAND_DID_ITS_WORK:
            self.log(
                "[red]live score failed[/] -- the run goes on",
                instance=instance_id,
                exit_code=answer.returncode,
            )
            return
        self.report_result(instance_id)

    def report_result(self, instance_id):
        """Write the line of one score: the instance, and the total so far.

        - instance_id: the instance that was scored.

        `swebench_score.py` gives exit code 0 when ANY instance of the run id
        has a report, so the line reads the report of this instance itself.
        """
        if self.report_of(instance_id) is None:
            self.log(
                "[yellow]live score failed[/]: no report for the instance",
                instance=instance_id,
                exit_code=COMMAND_DID_ITS_WORK,
            )
            return
        resolved, evaluated = tally_reports(self.run_root)
        self.log(
            "[green]scored[/]",
            instance=instance_id,
            resolved=YES if instance_id in resolved else NO,
            total_resolved=len(resolved),
            total_scored=len(evaluated),
        )

#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "swebench==5.0.2",
#     "rich==15.0.0",
# ]
# ///
"""
swebench_score.py -- give a score to a SWE-bench predictions.jsonl file.

The official SWE-bench harness gives the score, and it uses docker. This
script is separate from `swebench_run.py`, so you can score a saved
predictions file again without a new agent run:

    uv run bench/swebench_run.py   bench/preds.jsonl   # make the patches (no docker)
    uv run bench/swebench_score.py bench/preds.jsonl   # give the score  (docker)

The predictions file says what to score. This script scores each instance in
that file. Use --instance-ids to score fewer.

Two conditions need care, and this script controls both:

  * Not enough memory. Nothing builds an image here: this script pulls the
    published x86_64 image of each instance for linux/amd64, before the
    harness of swebench 5.0.2 starts. On Apple Silicon
    docker runs these images with emulation. Parallel emulated containers
    use much memory, and docker can stop them (exit 137). So this script
    uses ONE worker, and it does an instance that did not run again, alone.
    A docker failure is thus not a permanent loss.

  * An honest number. The score is resolved / EVALUATED. An instance that did
    not run, because of a docker failure, is reported alone. It is NEVER part
    of the divisor. A docker failure is not an agent failure.

Only a docker failure goes on to the tally and the second try. Any other
error of the harness, for example a TypeError when the call does not agree
with the pinned harness, is a defect of this script. The script then stops
at once with exit code 5, and the message names the error.

BEFORE YOU START: docker must run, and it needs enough memory. 16 GB or more
is good on Apple Silicon, because docker emulates the x86_64 images. This
script asks the daemon first, and it stops with exit code 3 when the daemon
does not answer. The file name is swebench_score.py, and not swebench.py, so
that `import swebench` finds the installed library and not this file.

THE EXIT CODES:
  0  a score was made, and the report is beside the predictions
  2  the command line is not valid: the predictions file is absent, it holds
     no instance to score, or the run id is not a name
  3  the docker daemon does not answer
  4  docker ran, and no instance was evaluated. There is no score.
  5  the harness raised an error that is not a docker failure. This is a
     defect of this script, and there is no score.

HOW TO USE IT:
  uv run bench/swebench_score.py bench/preds.jsonl
  uv run bench/swebench_score.py bench/preds.jsonl --max-workers 2 --run-id rescore
  uv run bench/swebench_score.py bench/preds.jsonl --instance-ids django__django-10914
"""
import argparse
import json
import os
import time
from pathlib import Path

import docker
from rich.markup import escape
from rich.table import Table
from swebench.harness.run_evaluation import main as run_harness
from swebench.harness.utils import load_swebench_dataset

from swebench_common import console, log
from swebench_harness import (
    IMAGE_PLATFORM,
    HarnessCallError,
    call_harness,
    harness_arguments,
    is_memory_failure,
)
from swebench_docker import (
    HOST_VARIABLE,
    daemon_answers,
    ensure_host,
    missing_daemon_message,
)
from swebench_report import (
    RunIdError,
    checked_run_id,
    score_report,
    write_report,
)

# --- config -----------------------------------------------------------------
# The harness of swebench 5.0.2 reads the image, the log parser and the eval
# script of each instance from the dataset. "SWE-bench/SWE-bench_Lite" has
# these fields. "princeton-nlp/SWE-bench_Lite" has the same instances, but it
# does not have these fields, and the harness then stops with KeyError 'image'.
DATASET = "SWE-bench/SWE-bench_Lite"
SPLIT = "test"
HARNESS_TIMEOUT = 1800   # the test limit of one instance in the container, in seconds
# This script pulls the published image of each instance. On Apple Silicon
# docker emulates these x86_64 images, and parallel emulated containers are
# the first cause of a memory failure.
DEFAULT_WORKERS = 1
# The exit codes of this script. A person reads them, and so does a pipeline
# that drives a run. The docstring above holds the same table.
BAD_INPUT_EXIT = 2        # the command line is not valid: the file, the ids
                          # or the run id
NO_DOCKER_EXIT = 3        # the docker daemon does not answer
NOTHING_EVALUATED_EXIT = 4  # docker ran, and no instance was evaluated
HARNESS_ERROR_EXIT = 5     # the harness raised an error that is not a docker failure
# One worker for the second try of an instance that did not run. Parallel
# emulated containers are the first cause of a docker failure.
RETRY_WORKERS = 1
# What stands between two ids in ONE field. No space stands there, because a
# space ends a field and `grep ids=` must find the whole list.
ID_SEPARATOR = ","
# How many places of a percentage a line holds. A score of 66.7 is enough for
# a person, and the report beside the predictions holds the full number.
PERCENT_PLACES = 1
# ----------------------------------------------------------------------------

# `console` and `log` come from swebench_common, so the run script and this
# script write their lines the same way.
#
# A MILESTONE of the run goes to `log`: a constant message, and then each value
# after a name of its own. `swebench_event.py` says why.
#
# An ERROR MESSAGE goes to `console.print`, and it stays a sentence. Such a
# message is the LAST thing this script writes: it names the cause, it says
# what a person must do, and the script then stops with an exit code of its
# own. The exit code is what a machine reads there, and a name and a value
# would only make that sentence hard to read.


def parse_args():
    """Read the command line, and return the parsed arguments."""
    p = argparse.ArgumentParser(
        description="Give a score to a SWE-bench predictions.jsonl (docker)."
    )
    p.add_argument("predictions", type=Path, help="the path of predictions.jsonl")
    p.add_argument(
        "--run-id", default=None,
        help="the harness run id (default: score_<time>)",
    )
    p.add_argument(
        "--max-workers", type=int, default=None, metavar="N",
        help="how many docker workers run together (default: 1). Each parallel emulated container "
             "needs 2 GB to "
             "4 GB. Keep the number low unless docker has much memory.",
    )
    p.add_argument(
        "--instance-ids", nargs="+", default=None, metavar="ID",
        help="these instance ids only (default: every id in the file)",
    )
    p.add_argument(
        "--no-retry-errors", dest="retry_errors", action="store_false",
        help="do NOT do an errored instance again alone (by default an instance "
             "that did not run gets one more try, alone, with one worker)",
    )
    return p.parse_args()


def load_predictions(path, only_ids):
    """Read predictions.jsonl into a list of dicts, and keep only_ids only."""
    rows = []
    with path.open() as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            rows.append(json.loads(ln))
    if only_ids:
        keep = set(only_ids)
        rows = [r for r in rows if r["instance_id"] in keep]
    return rows


def joined_ids(instance_ids):
    """The ids of a group, as ONE field of a line.

    - instance_ids: the ids to name.

    A field ends at a space, so the ids stand beside `ID_SEPARATOR` and not
    beside a comma and a space. `grep ids=` thus gives the whole group.
    """
    return ID_SEPARATOR.join(instance_ids)


def require_docker():
    """Stop the score step when the docker daemon does not answer.

    The harness starts a container for each instance, so a daemon that does not
    run makes every instance fail. The report then says `"resolved": 0`, and
    that reads like a failure of the agent.

    So this asks the daemon BEFORE the harness starts, and it names the
    endpoint it tried. `ensure_host` chooses that endpoint, because the docker
    library finds the socket of Docker Desktop only with `DOCKER_HOST`.
    """
    host = ensure_host(os.environ)
    if host:
        log(
            "[dim]the docker endpoint[/]",
            variable=HOST_VARIABLE,
            endpoint=host,
        )
    if daemon_answers():
        return
    console.print(f"[red]{missing_daemon_message(host)}[/]")
    raise SystemExit(NO_DOCKER_EXIT)


def chosen_run_id(named):
    """The run id of this score run, or stop with `BAD_INPUT_EXIT`.

    - named: the run id of `--run-id`, or None for the run id of the time.

    The run id becomes part of two paths: the name of the report file, and
    the directory of the logs that `tally` reads. So it must be a NAME. A run
    id such as `../../etc/hostname` writes outside the directory of the
    predictions, and `checked_run_id` refuses it.

    The refusal comes BEFORE the harness starts. A person thus reads the
    cause at once, and not after hours of work.
    """
    try:
        return checked_run_id(named or f"score_{time.strftime('%Y%m%d_%H%M%S')}")
    except RunIdError as refused:
        console.print(f"[red]{refused}[/]")
        raise SystemExit(BAD_INPUT_EXIT) from refused


def tally(run_id):
    """Read the report.json files of the run.

    Returns (resolved_ids, evaluated_ids). This is safe if the harness stops
    in the middle, and it is safe if a second try writes over a report with a
    new result.
    """
    resolved, evaluated = set(), set()
    root = Path("logs/run_evaluation") / run_id
    for rep in root.glob("*/*/report.json"):
        try:
            d = json.loads(rep.read_text())
        except Exception:
            continue
        if not d:
            continue
        k = next(iter(d))
        evaluated.add(k)
        if d[k].get("resolved"):
            resolved.add(k)
    return resolved, evaluated


def pull_images(instance_ids):
    """Pull the x86_64 image of each instance before the harness starts.

    - instance_ids: the ids whose images to pull.

    The harness pulls an image with no platform. On Apple Silicon docker then
    asks for linux/arm64, and the published images have no arm64 manifest, so
    each pull fails with a 404. This pulls each image for `IMAGE_PLATFORM`.
    The harness then finds the image on the machine, and it pulls nothing.

    An image that docker cannot pull is logged, and the run goes on. That
    instance does not run, and the report gives it alone as not run.
    """
    client = docker.from_env()
    for row in load_swebench_dataset(DATASET, SPLIT, list(instance_ids)):
        image = row["image"]
        try:
            client.images.get(image)
            continue
        except docker.errors.ImageNotFound:
            pass
        log(
            "[dim]pulling the image of an instance[/]",
            instance=row["instance_id"],
            image=image,
            platform=IMAGE_PLATFORM,
        )
        try:
            client.images.pull(image, platform=IMAGE_PLATFORM)
        except docker.errors.DockerException as failure:
            log(
                "[yellow]docker did not pull the image, and that instance "
                "will not run[/]",
                instance=row["instance_id"],
                error=failure,
            )


def run_once(instance_ids, workers, run_id, pred_path):
    """Do one harness pass.

    - instance_ids: the ids to evaluate.
    - workers: how many docker workers run together.
    - run_id: the harness run id.
    - pred_path: the path of predictions.jsonl.

    A docker failure (a pull, a container, exit 137) makes run_harness
    raise. But an instance that DID run has its report.json on disk already.
    So this logs a docker failure, and tally() reads what completed.

    Any other error is a defect of this script, for example a TypeError when
    the call does not agree with the pinned harness. A second try cannot
    correct it, so this stops at once with `HARNESS_ERROR_EXIT`.
    """
    arguments = harness_arguments(
        dataset_name=DATASET,
        split=SPLIT,
        instance_ids=instance_ids,
        predictions_path=pred_path.resolve(),
        max_workers=workers,
        run_id=run_id,
        timeout=HARNESS_TIMEOUT,
    )
    try:
        failure = call_harness(run_harness, arguments)
    except HarnessCallError as defect:
        console.print(f"[red]{escape(str(defect))}[/]")
        raise SystemExit(HARNESS_ERROR_EXIT) from defect
    if failure is None:
        return
    log(
        "[yellow]docker failed in the harness, and the tally goes on[/]",
        error=failure,
    )
    if is_memory_failure(failure):
        log(
            "[yellow]docker stopped a container for memory; give docker "
            "more memory, or use fewer workers[/]"
        )


def main():
    """Score the predictions file, and write the report beside it.

    The daemon of docker answers first, or this stops. Then it does one
    harness pass, and one more pass for each instance that did not run. It
    writes the table to standard output, and the machine-readable report to a
    JSON file beside the predictions.

    A run that evaluated no instance writes no report, and it stops with
    `NOTHING_EVALUATED_EXIT`. Such a report says `"resolved": 0`, and a
    reader takes that for a failure of the agent.
    """
    args = parse_args()
    pred_path = args.predictions
    if not pred_path.exists():
        console.print(f"[red]no such predictions file:[/] {pred_path}")
        raise SystemExit(BAD_INPUT_EXIT)

    rows = load_predictions(pred_path, args.instance_ids)
    if not rows:
        console.print("[red]nothing to score[/] (the file is empty, or no id agreed)")
        raise SystemExit(BAD_INPUT_EXIT)

    ids = [r["instance_id"] for r in rows]
    nonempty = [r["instance_id"] for r in rows if r.get("model_patch", "").strip()]
    run_id = chosen_run_id(args.run_id)
    workers = (
        args.max_workers if args.max_workers is not None
        else DEFAULT_WORKERS
    )

    console.rule(f"SWE-bench score . {pred_path.name}")
    log(
        "[green]the instances of this score run[/]",
        instances=len(ids),
        not_empty=len(nonempty),
        run_id=run_id,
        workers=workers,
    )
    require_docker()
    log("The first step pulls one image for each instance, and it is slow.")
    pull_images(nonempty)

    t0 = time.monotonic()
    run_once(ids, workers, run_id, pred_path)
    resolved, evaluated = tally(run_id)
    errored = [i for i in ids if i not in evaluated]

    # A docker failure is a machine condition, and not an agent failure. Do
    # each instance that did not run one more time, alone, with one worker. Then
    # the number shows the patches, and not the memory of docker.
    if errored and args.retry_errors:
        log(
            "[yellow]these instances did not run, and a docker failure is the "
            "usual cause; doing them again, alone, with one worker[/]",
            instances=len(errored),
            ids=joined_ids(errored),
        )
        run_once(errored, RETRY_WORKERS, run_id, pred_path)
        resolved, evaluated = tally(run_id)
        errored = [i for i in ids if i not in evaluated]

    dt = (time.monotonic() - t0) / 60
    report = score_report(
        run_id,
        predictions=pred_path,
        submitted=len(ids),
        evaluated=evaluated,
        resolved=resolved,
        errored=errored,
        minutes=dt,
    )
    if errored:
        log(
            "[red]these instances did NOT run; the lines of the harness give "
            "the docker failure[/]",
            instances=len(errored),
            ids=joined_ids(errored),
        )

    # No instance ran, so there is no score. A report of such a run says
    # `"resolved": 0`, and a reader takes that for a failure of the agent.
    out = write_report(pred_path, report)
    if out is None:
        console.print(
            f"[red]no instance was evaluated[/] ({report['submitted']} sent). "
            "Docker evaluated no instance, so there is no score and this run "
            "writes no report. Read the docker failure in the lines of the "
            "harness above."
        )
        raise SystemExit(NOTHING_EVALUATED_EXIT)

    total, ev, res = report["submitted"], report["evaluated"], report["resolved"]
    pct_eval = report["resolved_pct_of_evaluated"]
    pct_total = report["resolved_pct_of_submitted"]
    log(
        "[bold green]the score: resolved of evaluated[/]",
        resolved=res,
        evaluated=ev,
        percent_of_evaluated=round(pct_eval, PERCENT_PLACES),
        submitted=total,
        percent_of_submitted=round(pct_total, PERCENT_PLACES),
    )

    table = Table(
        title=f"score complete . {pred_path.name}",
        show_header=False, title_style="bold",
    )
    table.add_column(style="bold")
    table.add_column()
    table.add_row("sent", str(total))
    table.add_row("evaluated", str(ev))
    table.add_row("resolved", f"[green]{res}[/]")
    table.add_row("not resolved", f"[yellow]{report['unresolved']}[/]")
    table.add_row(
        "did not run",
        f"[red]{len(errored)}[/]" if errored else "0",
    )
    table.add_row("RESOLVED", f"[bold green]{res}/{ev} = {pct_eval:.1f}%[/] of evaluated")
    table.add_row("run id", run_id)
    table.add_row("wall time", f"{dt:.1f} min")
    console.print()
    console.print(table)
    log("the report of this score run", report=out)


if __name__ == "__main__":
    main()

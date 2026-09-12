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

  * Not enough memory. On Apple Silicon the harness builds x86_64 images with
    emulation. Parallel builds use much memory, and docker stops them (exit
    137). One stopped build makes an error for every instance that uses the
    same environment. So this script uses ONE worker for a local build, and it
    does an instance that errors again, alone, with a clean build. A memory
    failure is thus not a permanent loss.

  * An honest number. The score is resolved / EVALUATED. An instance that did
    not run, because of a build error, is reported alone. It is NEVER part of
    the divisor. A memory failure is not an agent failure.

BEFORE YOU START: docker must run, and it needs enough memory. 16 GB or more
is good on Apple Silicon, because the images are emulated x86_64 builds. This
script asks the daemon first, and it stops with exit code 3 when the daemon
does not answer. The file name is swebench_score.py, and not swebench.py, so
that `import swebench` finds the installed library and not this file.

THE EXIT CODES:
  0  a score was made, and the report is beside the predictions
  2  the command line is not valid: the predictions file is absent, it holds
     no instance to score, or the run id is not a name
  3  the docker daemon does not answer
  4  docker ran, and no instance was evaluated. There is no score.

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

from rich.table import Table
from swebench.harness.run_evaluation import main as run_harness

from swebench_common import console, log
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
DATASET = "princeton-nlp/SWE-bench_Lite"
SPLIT = "test"
HARNESS_TIMEOUT = 1800   # the test limit of one instance in the container, in seconds
NAMESPACE = None         # None => build the images here. Apple Silicon NEEDS this.
# The Python API wants None, and not "". main() does not correct "" like the
# command line does, and "" makes an invalid "/sweb.eval..." image name.
LOCAL_BUILD = "local-build"  # what the namespace field of a line says for None
LOCAL_DEFAULT_WORKERS = 1  # parallel emulated builds are the first cause of failure
REMOTE_DEFAULT_WORKERS = 4
# The exit codes of this script. A person reads them, and so does a pipeline
# that drives a run. The docstring above holds the same table.
BAD_INPUT_EXIT = 2        # the command line is not valid: the file, the ids
                          # or the run id
NO_DOCKER_EXIT = 3        # the docker daemon does not answer
NOTHING_EVALUATED_EXIT = 4  # docker ran, and no instance was evaluated
# One worker, and a clean build, for the second try of an instance that did
# not run. A parallel emulated build is the first cause of a build error.
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
        help="how many docker workers run together (default: 1 for a local "
             "build, 4 if not). Each parallel emulated build needs 2 GB to "
             "4 GB. Keep the number low unless docker has much memory.",
    )
    p.add_argument(
        "--instance-ids", nargs="+", default=None, metavar="ID",
        help="these instance ids only (default: every id in the file)",
    )
    p.add_argument(
        "--no-retry-errors", dest="retry_errors", action="store_false",
        help="do NOT do an errored instance again alone (by default a build "
             "error causes one more try, alone, with a clean build)",
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

    The harness builds an image for each instance, so a daemon that does not
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


def run_once(instance_ids, workers, force_rebuild, run_id, pred_path):
    """Do one harness pass.

    A build that runs out of memory (exit 137) makes run_harness raise. But an
    instance whose image DID build has its report.json on disk already. So
    this catches the error, and tally() reads what completed.
    """
    try:
        run_harness(
            dataset_name=DATASET,
            split=SPLIT,
            instance_ids=list(instance_ids),
            predictions_path=str(pred_path.resolve()),
            max_workers=workers,
            force_rebuild=force_rebuild,
            cache_level="env",
            clean=False,
            open_file_limit=4096,
            run_id=run_id,
            timeout=HARNESS_TIMEOUT,
            namespace=NAMESPACE,
            rewrite_reports=False,
            modal=False,
        )
    except Exception as exc:
        log(
            "[yellow]the harness raised an error, and the tally goes on[/]",
            error=exc,
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
        else (LOCAL_DEFAULT_WORKERS if NAMESPACE is None else REMOTE_DEFAULT_WORKERS)
    )

    console.rule(f"SWE-bench score . {pred_path.name}")
    log(
        "[green]the instances of this score run[/]",
        instances=len(ids),
        not_empty=len(nonempty),
        run_id=run_id,
        workers=workers,
        namespace=NAMESPACE or LOCAL_BUILD,
    )
    require_docker()
    log("The first pass builds one image for each instance, and it is slow.")

    t0 = time.monotonic()
    run_once(ids, workers, False, run_id, pred_path)
    resolved, evaluated = tally(run_id)
    errored = [i for i in ids if i not in evaluated]

    # A build error is a machine condition, and not an agent failure. Do each
    # instance that did not run one more time, alone, with a clean build. Then
    # the number shows the patches, and not the memory of docker.
    if errored and args.retry_errors:
        log(
            "[yellow]these instances did not run, and a build error is the "
            "usual cause; doing them again, alone, with a clean build[/]",
            instances=len(errored),
            ids=joined_ids(errored),
        )
        run_once(errored, RETRY_WORKERS, True, run_id, pred_path)
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
            "[red]these instances did NOT run, and the cause is a build "
            "error[/]",
            instances=len(errored),
            ids=joined_ids(errored),
        )

    # No instance ran, so there is no score. A report of such a run says
    # `"resolved": 0`, and a reader takes that for a failure of the agent.
    out = write_report(pred_path, report)
    if out is None:
        console.print(
            f"[red]no instance was evaluated[/] ({report['submitted']} sent). "
            "Docker built no image, so there is no score and this run writes "
            "no report. Read the lines of the harness above: exit code 137 is "
            "a memory failure, and docker then needs more memory."
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

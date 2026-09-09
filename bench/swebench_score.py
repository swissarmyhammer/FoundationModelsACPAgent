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

    uv run bench/swebench_run.py   preds.jsonl   # make the patches (no docker)
    uv run bench/swebench_score.py preds.jsonl   # give the score  (docker)

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
is good on Apple Silicon, because the images are emulated x86_64 builds. The
file name is swebench_score.py, and not swebench.py, so that `import swebench`
finds the installed library and not this file.

HOW TO USE IT:
  uv run bench/swebench_score.py preds.jsonl
  uv run bench/swebench_score.py preds.jsonl --max-workers 2 --run-id rescore
  uv run bench/swebench_score.py preds.jsonl --instance-ids django__django-10914
"""
import argparse
import json
import os
import subprocess
import time
from pathlib import Path

from rich.table import Table
from swebench.harness.run_evaluation import main as run_harness

from swebench_common import console, log

# --- config -----------------------------------------------------------------
DATASET = "princeton-nlp/SWE-bench_Lite"
SPLIT = "test"
HARNESS_TIMEOUT = 1800   # the test limit of one instance in the container, in seconds
NAMESPACE = None         # None => build the images here. Apple Silicon NEEDS this.
# The Python API wants None, and not "". main() does not correct "" like the
# command line does, and "" makes an invalid "/sweb.eval..." image name.
LOCAL_DEFAULT_WORKERS = 1  # parallel emulated builds are the first cause of failure
REMOTE_DEFAULT_WORKERS = 4
# ----------------------------------------------------------------------------

# `console` and `log` come from swebench_common, so the run script and this
# script write their lines the same way.


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


def ensure_docker_host():
    """Set DOCKER_HOST when the default socket is not there.

    The docker library speaks to /var/run/docker.sock by default. Docker
    Desktop puts the socket below the home directory of the user. If the
    default is absent, and DOCKER_HOST is not set, point it at the endpoint of
    the active context. If not, from_env() stops with a FileNotFoundError.
    """
    if os.environ.get("DOCKER_HOST") or Path("/var/run/docker.sock").exists():
        return
    try:
        host = subprocess.run(
            ["docker", "context", "inspect", "--format",
             "{{.Endpoints.docker.Host}}"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        if host:
            os.environ["DOCKER_HOST"] = host
            log(f"[dim]DOCKER_HOST -> {host}[/]")
    except Exception:
        pass


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
        log(f"[yellow]the harness raised an error (the tally continues):[/] {exc}")


def main():
    """Score the predictions file, and write the summary beside it.

    This does one harness pass, then one more pass for each instance that did
    not run. It writes the table to standard output, and the machine-readable
    summary to a JSON file beside the predictions.
    """
    args = parse_args()
    pred_path = args.predictions
    if not pred_path.exists():
        console.print(f"[red]no such predictions file:[/] {pred_path}")
        raise SystemExit(2)

    rows = load_predictions(pred_path, args.instance_ids)
    if not rows:
        console.print("[red]nothing to score[/] (the file is empty, or no id agreed)")
        raise SystemExit(2)

    ids = [r["instance_id"] for r in rows]
    nonempty = [r["instance_id"] for r in rows if r.get("model_patch", "").strip()]
    run_id = args.run_id or f"score_{time.strftime('%Y%m%d_%H%M%S')}"
    workers = (
        args.max_workers if args.max_workers is not None
        else (LOCAL_DEFAULT_WORKERS if NAMESPACE is None else REMOTE_DEFAULT_WORKERS)
    )

    console.rule(f"SWE-bench score . {pred_path.name}")
    log(
        f"[green]{len(ids)} instances[/] ({len(nonempty)} not empty) -> "
        f"run_id={run_id}, workers={workers}, namespace={NAMESPACE or 'local-build'}"
    )
    log("docker must run. The first pass builds one image for each instance, and it is slow.")
    ensure_docker_host()

    t0 = time.monotonic()
    run_once(ids, workers, False, run_id, pred_path)
    resolved, evaluated = tally(run_id)
    errored = [i for i in ids if i not in evaluated]

    # A build error is a machine condition, and not an agent failure. Do each
    # instance that did not run one more time, alone, with a clean build. Then
    # the number shows the patches, and not the memory of docker.
    if errored and args.retry_errors:
        log(
            f"[yellow]{len(errored)} instance(s) did not run[/] "
            f"(a build error is the usual cause); doing them again, alone, "
            f"with a clean build: {', '.join(errored)}"
        )
        run_once(errored, 1, True, run_id, pred_path)
        resolved, evaluated = tally(run_id)
        errored = [i for i in ids if i not in evaluated]

    dt = (time.monotonic() - t0) / 60
    total, ev, res = len(ids), len(evaluated), len(resolved)
    unresolved = sorted(evaluated - resolved)
    pct_eval = 100 * res / ev if ev else 0.0
    pct_total = 100 * res / total if total else 0.0

    log(
        f"[bold green]resolved {res}/{ev} evaluated = {pct_eval:.1f}%[/]  "
        f"[dim]({res}/{total} of all sent = {pct_total:.1f}%)[/]"
    )
    if errored:
        log(f"[red]{len(errored)} did NOT run[/] (a build error): " + ", ".join(errored))

    table = Table(
        title=f"score complete . {pred_path.name}",
        show_header=False, title_style="bold",
    )
    table.add_column(style="bold")
    table.add_column()
    table.add_row("sent", str(total))
    table.add_row("evaluated", str(ev))
    table.add_row("resolved", f"[green]{res}[/]")
    table.add_row("not resolved", f"[yellow]{len(unresolved)}[/]")
    table.add_row(
        "did not run",
        f"[red]{len(errored)}[/]" if errored else "0",
    )
    table.add_row("RESOLVED", f"[bold green]{res}/{ev} = {pct_eval:.1f}%[/] of evaluated")
    table.add_row("run id", run_id)
    table.add_row("wall time", f"{dt:.1f} min")
    console.print()
    console.print(table)

    # A durable summary, in a machine-readable form, beside the predictions.
    out = pred_path.with_suffix(pred_path.suffix + f".score.{run_id}.json")
    out.write_text(json.dumps({
        "run_id": run_id,
        "predictions": str(pred_path),
        "submitted": total,
        "evaluated": ev,
        "resolved": res,
        "unresolved": len(unresolved),
        "errored": errored,
        "resolved_ids": sorted(resolved),
        "unresolved_ids": unresolved,
        "errored_ids": errored,
        "resolved_pct_of_evaluated": pct_eval,
        "resolved_pct_of_submitted": pct_total,
        "wall_minutes": dt,
    }, indent=2) + "\n")
    log(f"summary -> [bold]{out}[/]")


if __name__ == "__main__":
    main()

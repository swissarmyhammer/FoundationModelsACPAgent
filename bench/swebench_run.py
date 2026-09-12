#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "datasets==5.0.1",
#     "rich==15.0.0",
#     "swebench==4.0.5",
# ]
# ///
"""
swebench_run.py -- make the SWE-bench predictions of the `acp-agent` binary.

For each task this script does five steps. It clones the buggy repository, it
sets the repository to the commit before the fix, it builds the Python
environment of that instance, it runs `acp-agent run` in that repository, and
it writes the source diff the agent made into a predictions file.

The `swebench` pin is 4.0.5, and not the 5.0.2 of `swebench_score.py`. This
script reads `MAP_REPO_VERSION_TO_SPECS` for the environment of each instance,
and that table is absent from 5.0.2.

This script does NOT give a score. `swebench_score.py` gives the score, and it
needs docker. The two steps are separate because they fail in different ways.
The agent run is long and expensive. The docker step is short but it can run
out of memory. Keep the predictions on disk, and score them as many times as
you must:

    uv run bench/swebench_run.py   bench/preds.jsonl   # this script: patches only
    uv run bench/swebench_score.py bench/preds.jsonl   # the score, with docker

This script APPENDS, so it can CONTINUE. If the predictions file has results
already, this script does the other instances only. Use --force to do all the
instances again. If a run stops, start it again to continue.

The predictions file KEEPS the patch of an instance, in all conditions. An
agent that goes past the time limit is stopped, and the row of that instance
carries `truncated` as well. The tree of a stopped agent can hold the correct
answer, so this step keeps the work and the score step decides what to do with
it. `swebench_prediction.py` makes the row, and it says why.

The file name is swebench_run.py, and not swebench.py. A file with the name
swebench.py in this directory hides the installed `swebench` package.

==============================================================================
WHAT THE AGENT GETS
==============================================================================
The agent gets the problem statement of the instance, and nothing more. There
is no skill and no workflow, because this package has no skills yet. The
prompt goes to the standard input of the agent, so no shell quotes and no
argument length can change it.

The agent gets ONE turn. `acp-agent run` starts a new session, sends the
prompt, and stops when the turn stops.

The agent gets a CLEAN environment, and not the environment of this script.
`uv run --script` makes an ephemeral environment for this script, and a child
that gets it finds the Python of the HARNESS. The agent then does work that
is not the task: it looks in the cache of `uv`, and it tries to install
packages there. `swebench_env.py` says what the agent keeps and what it
loses, and each instance writes a log line with the Python the agent gets.

==============================================================================
THE ENVIRONMENT OF THE INSTANCE
==============================================================================
A SWE-bench repository does not import from a source checkout, so the agent
cannot run one test of the instance until something builds the environment.

In the run of 2026-09-11 the agent had to do that work itself, and it was the
largest cost of the run: 219 of 707 tool calls were about pip, uv, virtual
environments or absent modules. For `astropy__astropy-6938` it was 37 of 80
calls, and the agent never got a working environment.

So this script builds it first. `swebench_venv.py` reads the spec of the
instance, makes a virtual environment in the clone with `uv`, installs the
packages of the spec, and puts that environment first on the PATH of the
agent. The agent then gets the task, and not the environment.

Two groups of instances do not build on this machine: 77 want Python 3.6,
which `uv` does not build for arm64, and 44 have a `pre_install` that is
written for linux. Each of them is recorded and left out, and the agent does
not start for it. A failed environment is not a failure of the agent, so the
instance gets NO prediction row and it is not part of the score.
`--oldest-python 3.8` gives the first group a Python to try.

The agent writes its session transcripts into the repository, and the
repository is removed when the instance ends. So this script copies the
transcripts out first, into `<preds stem>.transcripts/<instance_id>/` beside
the predictions file. Read them to see what the model did in each round.

Each instance also gets one row in `<preds stem>.runs.jsonl`, beside the
predictions. That row says how long the instance took, how long the clone and
the agent each took, how the agent stopped, and how large the patch is. The
run of 2026-09-11 kept no log, and all of that data had to be built again from
the transcripts. `swebench_record.py` makes the row, and it says why.

==============================================================================
BEFORE YOU START
==============================================================================
Build the agent first:

    swift build -c release

These programs must be on the PATH:
    uv    -- runs this script, and gets its dependencies
    git   -- clones the repository of each task

The machine must have the memory the agent needs. Read the README of the
package. The agent loads its models on each instance, because each instance
runs a new process.

==============================================================================
HOW TO USE IT
==============================================================================
  uv run bench/swebench_run.py bench/preds.jsonl               # all instances
  uv run bench/swebench_run.py bench/preds.jsonl --limit 5     # the first 5
  uv run bench/swebench_run.py bench/preds.jsonl --force       # do them again
  uv run bench/swebench_run.py bench/preds.jsonl -i django__django-11099
  uv run bench/swebench_run.py bench/preds.jsonl --oldest-python 3.8
  uv run bench/swebench_score.py bench/preds.jsonl             # then the score
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from datasets import load_dataset
from rich.table import Table

from swebench_common import console, log
from swebench_env import environment_fields
from swebench_prediction import prediction_row
from swebench_record import append_row, patch_file_count, run_record, runs_path
from swebench_venv import (
    BUILT,
    UNSUPPORTED,
    instance_environment,
    prepare_environment,
)

# --- config -----------------------------------------------------------------
DATASET = "princeton-nlp/SWE-bench_Lite"
SPLIT = "test"
# The name that goes in each prediction row. The score report file uses it.
MODEL_NAME = "acp-agent"
# The wall-clock limit of one instance. The agent is a local model, and it is
# much slower than a hosted model. One tool call can need ten minutes.
DEFAULT_TIMEOUT_S = 3600
# The directories that this script and the agent write in the repository:
# the transcripts of the agent, and the Python environment of the instance.
# `git diff <commit>` reports tracked files only, so these are already out of
# the patch. These pathspecs are the second guard, for a run that COMMITS one
# of them.
AGENT_EXCLUDES = [".acp-agent", ".venv"]
# Where the agent writes its session transcripts, below the repository. The
# repository is removed when the instance ends, so the transcripts are copied
# out first. They are the only record of what the model did in each round.
AGENT_TRANSCRIPTS = Path(".acp-agent") / "transcripts"
# Where to look for the agent binary, in this order, below the package root.
AGENT_CANDIDATES = (".build/release/acp-agent", ".build/debug/acp-agent")
# The package root: the parent of this `bench` directory.
PACKAGE_ROOT = Path(__file__).resolve().parent.parent
# How many letters of a commit the line of an instance holds. A name of this
# length says which commit it is, and `git` itself reads one.
SHORT_COMMIT = 10
# How many minutes are in an hour, and how many seconds are in a minute. The
# summary of a run gives its wall time in minutes.
SECONDS_OF_A_MINUTE = 60
# How many numbers after the point the wall time of a run holds.
MINUTE_PLACES = 1
# ----------------------------------------------------------------------------

parser = argparse.ArgumentParser(
    description="Make a SWE-bench predictions.jsonl with acp-agent (no score)."
)
parser.add_argument("outpath", type=Path, help="where to write predictions.jsonl")
parser.add_argument(
    "-n", "--limit", type=int, default=None, metavar="N",
    help="the first N instances only (default: all of the split)",
)
parser.add_argument(
    "--force", action="store_true",
    help="do every instance again, and write over the predictions file "
         "(default: APPEND, and do not do an instance that is in the file)",
)
parser.add_argument(
    "-i", "--instance-ids", nargs="+", default=None, metavar="ID",
    help="these instance ids only (this replaces --limit), for example "
         "astropy__astropy-14182 django__django-11019",
)
parser.add_argument(
    "--agent", type=Path, default=None, metavar="PATH",
    help="the acp-agent binary (default: the release build, then the debug "
         "build, then the PATH)",
)
parser.add_argument(
    "--timeout", type=int, default=DEFAULT_TIMEOUT_S, metavar="SECONDS",
    help=f"the wall-clock limit of one instance (default: {DEFAULT_TIMEOUT_S})",
)
parser.add_argument(
    "--oldest-python", default=None, metavar="VERSION",
    help="the Python to try when a spec wants one that uv cannot build, for "
         "example 3.8 (default: leave those 77 instances out)",
)
parser.add_argument(
    "--verbose", action="store_true",
    help="give --verbose to the agent, so it writes its session events",
)
args = parser.parse_args()
outpath = args.outpath
LIMIT = args.limit  # None => all of the split


def find_agent(explicit):
    """The path of the agent binary.

    An explicit path must exist. If there is no explicit path, this looks for
    the release build, then the debug build, then the PATH. If it finds
    nothing, it tells you to build the package.
    """
    if explicit is not None:
        path = explicit.resolve()
        if not path.exists():
            raise SystemExit(f"no such agent binary: {path}")
        return path
    for candidate in AGENT_CANDIDATES:
        path = PACKAGE_ROOT / candidate
        if path.exists():
            return path.resolve()
    found = shutil.which("acp-agent")
    if found:
        return Path(found)
    raise SystemExit(
        "cannot find the acp-agent binary. Build it first:\n"
        f"    cd {PACKAGE_ROOT} && swift build -c release\n"
        "or give the path with --agent PATH"
    )


AGENT = find_agent(args.agent)

# --- logging ----------------------------------------------------------------
# `console` and `log` come from swebench_common, so the score script and this
# script write their lines the same way. The predictions file, and not the
# output, is the durable result of a run.


def echo(line):
    """Write one raw line of agent output. It is indented and dim."""
    console.print(f"    {line}", markup=False, highlight=False, style="dim")


def stream_agent(cmd, cwd, prompt, timeout, environment):
    """Run the agent, and write its output line by line as it comes.

    The prompt goes to the standard input of the agent, and a thread writes
    it. A thread is necessary: a prompt that is larger than the pipe buffer
    fills the pipe, and a write from this thread would then stop until the
    agent reads. The agent writes its answer at the same time, so both sides
    would wait for each other.

    The agent runs in its OWN process group. A watchdog sends SIGTERM to the
    whole group at `timeout`, waits a short time, and then sends SIGKILL. The
    group is killed at the end in all conditions. This stops the model process
    and its children. If they stay alive they hold the temporary repository
    open, and they use the memory the docker score step needs.

    The agent gets the environment of the INSTANCE, and not the environment
    of this harness. `uv run --script` makes an ephemeral environment for this
    script, and a child that gets that environment finds the Python of the
    harness. `swebench_env.py` says what the agent keeps and what it loses,
    and `swebench_venv.py` puts the environment of the instance first on that
    PATH. The caller makes it, and it logs which Python the agent gets.

    - cmd: the command of the agent.
    - cwd: the directory the agent runs in.
    - prompt: the problem statement of the instance.
    - timeout: the wall-clock limit of the instance, in seconds.
    - environment: the environment of the process of the agent.

    Returns (returncode, timed_out).
    """
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,  # a new process group, so we can signal the tree
    )
    pgid = proc.pid  # with start_new_session the leader pid is the pgid
    timed_out = {"v": False}

    def _write_prompt():
        try:
            proc.stdin.write(prompt)
            proc.stdin.close()
        except (BrokenPipeError, ValueError):
            pass  # the agent stopped first; the exit code tells the story

    def _kill():
        timed_out["v"] = True
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            return
        for _ in range(20):  # about 10s, to let the agent write its files
            if proc.poll() is not None:
                break
            time.sleep(0.5)
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    writer = threading.Thread(target=_write_prompt, daemon=True)
    writer.start()
    timer = threading.Timer(timeout, _kill)
    timer.start()
    try:
        for line in proc.stdout:
            line = line.rstrip("\n")
            if line.strip():
                echo(line)
        proc.wait()
    finally:
        timer.cancel()
        try:  # kill the children that stay alive
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    return proc.returncode, timed_out["v"]


def patch_stats(patch):
    """(files, added, removed) of a unified diff, for the log line.

    `swebench_record.py` counts the files, because the record of an instance
    carries that count too. One count answers both, so the two cannot drift.
    """
    lines = patch.splitlines()
    files = patch_file_count(patch)
    added = sum(1 for ln in lines if ln.startswith("+") and not ln.startswith("+++"))
    removed = sum(1 for ln in lines if ln.startswith("-") and not ln.startswith("---"))
    return files, added, removed


def transcripts_dir(outpath):
    """The directory that keeps the agent transcripts of every instance.

    It sits beside the predictions file, with the same stem:
    `preds.jsonl` -> `preds.transcripts/<instance_id>/`. The `.gitignore` of
    the bench directory keeps `*.transcripts/` out of git.
    """
    return outpath.parent / f"{outpath.stem}.transcripts"


def keep_transcripts(repo, outpath, instance_id):
    """Copy the agent transcripts of one instance out of the repository.

    The repository is a temporary directory, and it is removed when the
    instance ends. Without this copy, no record of the model rounds survives
    the run. A copy replaces the copy of an earlier run of the same instance.

    Returns the destination, or None when the agent wrote no transcripts.
    """
    source = Path(repo) / AGENT_TRANSCRIPTS
    if not source.is_dir():
        return None
    destination = transcripts_dir(outpath) / instance_id
    if destination.exists():
        shutil.rmtree(destination, ignore_errors=True)
    shutil.copytree(source, destination)
    return destination


def capture_patch(repo, base_commit):
    """The source diff of the agent, against the CLEAN base commit.

    This is `git diff <base_commit>`, and not HEAD and not --cached. The agent
    can commit its change, and then the working tree is different from the
    base commit. `git diff <commit>` finds that change.

    `git diff <commit>` reports TRACKED files only. So every untracked file
    the agent writes is out of the patch, and you must NOT `git add -A` first.
    The AGENT_EXCLUDES pathspecs are the second guard.
    """
    excludes = [f":(exclude){p}" for p in AGENT_EXCLUDES]
    return subprocess.run(
        ["git", "-C", repo, "diff", base_commit, "--", ".", *excludes],
        capture_output=True, text=True, check=True,
    ).stdout


# --- load the dataset, and continue -----------------------------------------
console.rule(f"SWE-bench predictions . {MODEL_NAME} . {DATASET}")
log("agent binary", agent=AGENT)
log("loading the dataset from huggingface...")
dataset = load_dataset(DATASET, split=SPLIT)
all_instances = list(dataset)
if args.instance_ids:
    want = list(dict.fromkeys(args.instance_ids))  # remove copies, keep the order
    by_id = {i["instance_id"]: i for i in all_instances}
    missing = [w for w in want if w not in by_id]
    if missing:
        raise SystemExit(f"unknown instance id(s): {', '.join(missing)}")
    instances = [by_id[w] for w in want]
else:
    instances = all_instances[:LIMIT] if LIMIT else all_instances

done = set()
if outpath.exists() and outpath.stat().st_size and not args.force:
    for ln in outpath.read_text().splitlines():
        try:
            done.add(json.loads(ln)["instance_id"])
        except Exception:
            pass
    if done:
        log(
            "[yellow]continuing[/]: these instances are in the predictions "
            "file already, and this run does not do them again "
            "([bold]--force[/] does all of them again)",
            done=len(done),
            predictions=outpath,
        )

log(
    "[green]the instances of this run[/]",
    instances=len(instances),
    to_do=len(instances) - len(done),
    predictions=outpath,
)
log("the record of each instance", record=runs_path(outpath))

counts = {
    "patches": 0, "empty": 0, "timeouts": 0, "errors": 0, "skipped": 0,
    "env_failed": 0, "unsupported": 0,
}
t_all = time.monotonic()

# Both files are appended, and not written over, unless --force. The
# predictions file is what says which instances are done, and the record file
# says what each instance cost. `--force` does every instance again, so both
# files start again with it.
with outpath.open("w" if args.force else "a") as out, \
        runs_path(outpath).open("w" if args.force else "a") as runs:
    for n, inst in enumerate(instances, 1):
        instance_id = inst["instance_id"]
        repo_name = inst["repo"]
        # The fields that say which instance a line is about. Each line of
        # this instance carries them, so `grep instance=<id> run.log` gives
        # the whole story of one instance.
        about = {"instance": instance_id, "number": n, "of": len(instances)}
        if instance_id in done:
            counts["skipped"] += 1
            log("[dim]done already, and not done again[/]", **about)
            continue
        work = None
        # What the record of this instance holds. Each name keeps the value
        # of a step that did NOT run, so an instance that fails in the clone
        # still writes a whole row.
        kept = None
        clone_seconds = None
        agent_seconds = None
        exit_code = None
        timed_out = False
        patch = ""
        built = None
        t0 = time.monotonic()
        try:
            # 1. SET UP the buggy repository, at the commit before the fix.
            t_clone = time.monotonic()
            log("cloning", **about, repo=repo_name)
            # resolve(): on macOS mkdtemp gives a path below /var/folders,
            # and /var is a symbolic link to /private/var. The agent puts a
            # sandbox around its shell, and a sandbox compares real paths. So
            # give the agent the real path, and not the link.
            work = Path(tempfile.mkdtemp()).resolve()
            repo = work / "repo"
            subprocess.run(
                ["git", "clone", "--quiet",
                 f"https://github.com/{repo_name}.git", str(repo)],
                check=True, capture_output=True,
            )
            log("checkout", **about, commit=inst["base_commit"][:SHORT_COMMIT])
            subprocess.run(
                ["git", "-C", str(repo), "checkout", "--quiet", "--force",
                 inst["base_commit"]],
                check=True, capture_output=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "clean", "-fdx", "--quiet"],
                check=True, capture_output=True,
            )
            clone_seconds = time.monotonic() - t_clone

            # 2. BUILD THE PYTHON ENVIRONMENT of the instance, in the clone.
            #    A SWE-bench repository does not import from a source
            #    checkout, so without this step the agent spends its hour on
            #    pip. An instance that does not build here gets no prediction
            #    row: a failed environment is not a failure of the agent, and
            #    it must not be part of the score.
            log("building the environment...", **about)
            built = prepare_environment(
                repo,
                repo_name,
                inst["version"],
                oldest_python=args.oldest_python,
            )
            if built.status == UNSUPPORTED:
                counts["unsupported"] += 1
                log("[dim]not supported here[/]", **about, reason=built.reason)
                continue
            if built.status != BUILT:
                counts["env_failed"] += 1
                log("[yellow]NO ENVIRONMENT[/]", **about, reason=built.reason)
                if built.output:
                    echo(built.output)
                continue
            log(
                "the environment is ready",
                **about,
                python=built.python,
                seconds=round(built.seconds),
            )

            # 3. RUN THE AGENT in that repository. The prompt is the problem
            #    statement, and nothing more. `-` makes the agent read the
            #    prompt from its standard input, so no quote and no argument
            #    length can change the text.
            problem = inst["problem_statement"]
            environment = instance_environment(repo)
            log(
                "the environment of the agent",
                **about,
                **environment_fields(environment),
            )
            log("running the agent...", **about, limit_seconds=args.timeout)
            cmd = [str(AGENT), "run", "-", "--cwd", str(repo)]
            if args.verbose:
                cmd.append("--verbose")
            t_agent = time.monotonic()
            exit_code, timed_out = stream_agent(
                cmd, str(repo), problem, args.timeout, environment
            )
            agent_seconds = time.monotonic() - t_agent

            # 4. GET the source diff, against the clean base commit. The row
            #    KEEPS that diff in all conditions. An agent that the watchdog
            #    stopped gets `truncated` in its row, and nothing more: its
            #    tree can hold the correct answer, and this file is the
            #    durable record of the run. `swebench_prediction.py` says why.
            patch = capture_patch(str(repo), inst["base_commit"])

            append_row(
                out,
                prediction_row(
                    instance_id, MODEL_NAME, patch, truncated=timed_out
                ),
            )

            files, added, removed = patch_stats(patch)
            # What the agent made, and what it cost. These fields stand
            # beside the fields of the instance on the line of the result.
            shape = {
                "files": files,
                "added": added,
                "removed": removed,
                "seconds": round(time.monotonic() - t0),
            }
            if timed_out:
                counts["timeouts"] += 1
                log(
                    "[red]TOO SLOW[/] -- the patch is kept, and the row says "
                    "truncated",
                    **about,
                    **shape,
                )
            elif patch.strip():
                counts["patches"] += 1
                log("[green]done[/]", **about, **shape)
            else:
                counts["empty"] += 1
                log("[yellow]EMPTY patch[/]", **about, **shape)
        except Exception as exc:  # one bad instance must not stop the batch
            counts["errors"] += 1
            log("[red]ERROR[/]", **about, error=exc)
        finally:
            if work is not None:
                # Keep the transcripts before the repository goes. This runs
                # for a finished agent, a killed agent, and a failed step.
                try:
                    kept = keep_transcripts(work / "repo", outpath, instance_id)
                    if kept is not None:
                        log("transcripts", **about, path=kept)
                except OSError as exc:
                    log("[yellow]transcripts not kept[/]", **about, error=exc)
                shutil.rmtree(work, ignore_errors=True)
            # The record of the instance goes last, so that it can name the
            # transcripts. This runs for a finished agent, a stopped agent
            # and a failed step alike, and `append_row` flushes it. A run
            # that stops here thus keeps the record of every instance that
            # is complete.
            append_row(
                runs,
                run_record(
                    instance_id,
                    seconds=time.monotonic() - t0,
                    clone_seconds=clone_seconds,
                    agent_seconds=agent_seconds,
                    exit_code=exit_code,
                    timed_out=timed_out,
                    patch=patch,
                    transcript_path=kept,
                    env_status=None if built is None else built.status,
                    env_python=None if built is None else built.python,
                    env_seconds=None if built is None else built.seconds,
                    env_exit_code=None if built is None else built.exit_code,
                    env_reason=None if built is None else built.reason,
                ),
            )

# --- the summary ------------------------------------------------------------
total_dt = time.monotonic() - t_all
total_minutes = round(total_dt / SECONDS_OF_A_MINUTE, MINUTE_PLACES)
log(
    "[bold]complete[/]",
    patches=counts["patches"],
    empty=counts["empty"],
    too_slow=counts["timeouts"],
    no_environment=counts["env_failed"],
    not_supported=counts["unsupported"],
    errors=counts["errors"],
    not_done_again=counts["skipped"],
    minutes=total_minutes,
)
log(
    "get the score with [bold]uv run bench/swebench_score.py[/]",
    predictions=outpath,
)

table = Table(
    title=f"predictions complete . {MODEL_NAME}", show_header=False,
    title_style="bold",
)
table.add_column(style="bold")
table.add_column()
table.add_row("instances", str(len(instances)))
table.add_row("patches made", f"[green]{counts['patches']}[/]")
table.add_row("empty patches", f"[yellow]{counts['empty']}[/]")
table.add_row("too slow", f"[red]{counts['timeouts']}[/]" if counts["timeouts"] else "0")
table.add_row(
    "no environment",
    f"[yellow]{counts['env_failed']}[/]" if counts["env_failed"] else "0",
)
table.add_row("not supported", str(counts["unsupported"]))
table.add_row("errors", f"[red]{counts['errors']}[/]" if counts["errors"] else "0")
table.add_row("not done again", str(counts["skipped"]))
table.add_row("output", str(outpath))
table.add_row("record", str(runs_path(outpath)))
table.add_row("next", f"uv run bench/swebench_score.py {outpath}")
table.add_row("wall time", f"{total_minutes} min")
console.print()
console.print(table)

#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "datasets==5.0.1",
#     "rich==15.0.0",
#     "swebench==4.1.0",
# ]
# ///
"""
swebench_run.py -- make the SWE-bench predictions of the `acp-agent` binary.

For each task this script does five steps. It clones the buggy repository, it
sets the repository to the commit before the fix, it builds the Python
environment of the task, it runs `acp-agent run` in that repository, and it
writes the source diff the agent made into a predictions file.

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

The file name is swebench_run.py, and not swebench.py. A file with the name
swebench.py in this directory hides the installed `swebench` package.

==============================================================================
WHAT THE AGENT GETS
==============================================================================
The agent gets the problem statement of the instance, and a short note about
the environment. There is no skill and no workflow, because this package has
no skills yet. The prompt goes to the standard input of the agent, so no
shell quotes and no argument length can change it. Use --bare-prompt to send
the problem statement alone.

The agent gets ONE turn. `acp-agent run` starts a new session, sends the
prompt, and stops when the turn stops.

The agent writes its session transcripts into the repository, and the
repository is removed when the instance ends. So this script copies the
transcripts out first, into `<preds stem>.transcripts/<instance_id>/` beside
the predictions file. Read them to see what the model did in each round.

==============================================================================
THE ENVIRONMENT OF THE AGENT
==============================================================================
`swebench_env.py` builds the environment of each instance before the agent
starts: a virtual environment with the Python version of the task, the pinned
packages, and the repository installed. The `python` of that environment is
first on the PATH of the agent, so the model can import the package and read
a true traceback in its first minute.

This step is not a nicety. Without it the model finds a source tree it cannot
import, because the compiled extensions are absent. In the run of
astropy__astropy-12907 the model used 56 of its 60 minutes on build errors,
and it made no patch.

The build is NOT part of the limit of the agent, and the clock of the agent
starts after it. An instance whose environment cannot be built gets no
prediction row, so a later run does it again. Use --no-env to leave the
environment out.

==============================================================================
BEFORE YOU START
==============================================================================
Build the agent first:

    swift build -c release

These programs must be on the PATH:
    uv    -- runs this script, gets its dependencies, and builds each
             environment
    git   -- clones the repository of each task

A compiler is necessary too, because some repositories have C extensions. On
macOS the command line tools of Xcode are enough.

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
  uv run bench/swebench_run.py bench/preds.jsonl --no-env      # no environment
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

import swebench_env
from swebench_common import console, log

# --- config -----------------------------------------------------------------
DATASET = "princeton-nlp/SWE-bench_Lite"
SPLIT = "test"
# The note that goes after the problem statement. The model reads it with the
# task, and it says what the environment is and what the answer is. Without
# this note a model builds and installs, and that work is a loss: the score
# step runs the tests in its own container, and it uses the diff alone.
PROMPT_NOTE = """

# The environment of this task

The repository is installed already, and `python` on your PATH is the Python
of that install. Import the package and reproduce the problem in your first
step.

Do NOT make a virtual environment. Do NOT install a package, and do NOT
change the version of one. Do NOT build the package or its extensions. That
work is done.

The tests are run for you, on another machine, after you stop. Your answer is
the change you make in the source files, and nothing else.
"""
# The name that goes in each prediction row. The score report file uses it.
MODEL_NAME = "acp-agent"
# The wall-clock limit of one instance. The agent is a local model, and it is
# much slower than a hosted model. One tool call can need ten minutes.
DEFAULT_TIMEOUT_S = 3600
# The directories the agent writes in the repository. `git diff <commit>`
# reports tracked files only, so these are already out of the patch. These
# pathspecs are the second guard, for a run that COMMITS one of them.
AGENT_EXCLUDES = [".acp-agent"]
# Where the agent writes its session transcripts, below the repository. The
# repository is removed when the instance ends, so the transcripts are copied
# out first. They are the only record of what the model did in each round.
AGENT_TRANSCRIPTS = Path(".acp-agent") / "transcripts"
# Where to look for the agent binary, in this order, below the package root.
AGENT_CANDIDATES = (".build/release/acp-agent", ".build/debug/acp-agent")
# The package root: the parent of this `bench` directory.
PACKAGE_ROOT = Path(__file__).resolve().parent.parent
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
    "--verbose", action="store_true",
    help="give --verbose to the agent, so it writes its session events",
)
parser.add_argument(
    "--no-env", action="store_true",
    help="do not build the environment of the instance (default: build it, "
         "so the agent can import the package and run the code)",
)
parser.add_argument(
    "--env-timeout", type=int, default=swebench_env.DEFAULT_ENV_TIMEOUT_S,
    metavar="SECONDS",
    help="the wall-clock limit of one environment build (default: "
         f"{swebench_env.DEFAULT_ENV_TIMEOUT_S}). It is not part of the limit "
         "of the agent.",
)
parser.add_argument(
    "--bare-prompt", action="store_true",
    help="send the problem statement alone, with no note about the "
         "environment",
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


def stream_agent(cmd, cwd, prompt, timeout, env=None):
    """Run the agent, and write its output line by line as it comes.

    The prompt goes to the standard input of the agent, and a thread writes
    it. A thread is necessary: a prompt that is larger than the pipe buffer
    fills the pipe, and a write from this thread would then stop until the
    agent reads. The agent writes its answer at the same time, so both sides
    would wait for each other.

    `env` is the environment of the agent process, and the shell of the agent
    gets it too. The environment of the instance goes in there, so that
    `python` is the Python of the task.

    The agent runs in its OWN process group. A watchdog sends SIGTERM to the
    whole group at `timeout`, waits a short time, and then sends SIGKILL. The
    group is killed at the end in all conditions. This stops the model process
    and its children. If they stay alive they hold the temporary repository
    open, and they use the memory the docker score step needs.

    Returns (returncode, timed_out).
    """
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=env,
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
    """(files, added, removed) of a unified diff, for the log line."""
    lines = patch.splitlines()
    files = sum(1 for ln in lines if ln.startswith("diff --git "))
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
log(f"agent binary: [bold]{AGENT}[/]")
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
            f"[yellow]continuing[/]: {len(done)} instance(s) are in {outpath} "
            f"already, and this run does not do them again "
            f"(use [bold]--force[/] to do all of them again)"
        )

log(
    f"[green]{len(instances)} instances[/] ({len(instances) - len(done)} to do) "
    f"-> [bold]{outpath}[/]"
)

counts = {
    "patches": 0, "empty": 0, "timeouts": 0, "errors": 0, "skipped": 0,
    "setup": 0,
}
t_all = time.monotonic()

# The file is appended, and not written over, unless --force. The predictions
# file is what says which instances are done.
with outpath.open("w" if args.force else "a") as out:
    for n, inst in enumerate(instances, 1):
        instance_id = inst["instance_id"]
        repo_name = inst["repo"]
        prefix = f"[cyan][{n}/{len(instances)}][/] [bold]{instance_id}[/]"
        if instance_id in done:
            counts["skipped"] += 1
            log(f"{prefix} [dim]done already, and not done again[/]")
            continue
        work = None
        t0 = time.monotonic()
        try:
            # 1. SET UP the buggy repository, at the commit before the fix.
            log(f"{prefix} cloning {repo_name}")
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
            log(f"{prefix} checkout {inst['base_commit'][:10]}")
            subprocess.run(
                ["git", "-C", str(repo), "checkout", "--quiet", "--force",
                 inst["base_commit"]],
                check=True, capture_output=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "clean", "-fdx", "--quiet"],
                check=True, capture_output=True,
            )

            # 2. BUILD THE ENVIRONMENT of the task, before the agent starts.
            #    The clock of the agent starts after this, so a long build
            #    takes nothing from the model. An instance that cannot be
            #    built gets NO row, and a later run does it again.
            agent_env = None
            if not args.no_env:
                log(f"{prefix} building the environment (limit {args.env_timeout}s)...")
                t_env = time.monotonic()
                try:
                    venv = swebench_env.prepare(
                        work, repo, inst, timeout=args.env_timeout,
                    )
                except swebench_env.SetupFailed as exc:
                    counts["setup"] += 1
                    log(f"{prefix} [red]NO ENVIRONMENT[/] -- no row is written: {exc}")
                    continue
                agent_env = swebench_env.agent_environment(venv)
                log(f"{prefix} environment ready -- {time.monotonic() - t_env:.0f}s")

            # 3. RUN THE AGENT in that repository. The prompt is the problem
            #    statement, and the note about the environment. `-` makes the
            #    agent read the prompt from its standard input, so no quote
            #    and no argument length can change the text.
            problem = inst["problem_statement"]
            if agent_env is not None and not args.bare_prompt:
                problem += PROMPT_NOTE
            log(f"{prefix} running the agent (limit {args.timeout}s)...")
            cmd = [str(AGENT), "run", "-", "--cwd", str(repo)]
            if args.verbose:
                cmd.append("--verbose")
            _, timed_out = stream_agent(
                cmd, str(repo), problem, args.timeout, env=agent_env,
            )

            # 4. GET the source diff, against the clean base commit. An agent
            #    that the watchdog killed did not finish, and its half-written
            #    tree is not an answer. Record an empty patch for it.
            patch = capture_patch(str(repo), inst["base_commit"])
            if timed_out:
                patch = ""

            out.write(
                json.dumps({
                    "instance_id": instance_id,
                    "model_name_or_path": MODEL_NAME,
                    "model_patch": patch,
                }) + "\n"
            )
            out.flush()

            dt = time.monotonic() - t0
            if timed_out:
                counts["timeouts"] += 1
                log(f"{prefix} [red]TOO SLOW[/] -> an empty patch -- {dt:.0f}s")
            elif patch.strip():
                counts["patches"] += 1
                files, added, removed = patch_stats(patch)
                log(
                    f"{prefix} [green]done[/] -- "
                    f"{files} file(s) [green]+{added}[/]/[red]-{removed}[/] . {dt:.0f}s"
                )
            else:
                counts["empty"] += 1
                log(f"{prefix} [yellow]EMPTY patch[/] -- {dt:.0f}s")
        except Exception as exc:  # one bad instance must not stop the batch
            counts["errors"] += 1
            log(f"{prefix} [red]ERROR[/]: {exc}")
        finally:
            if work is not None:
                # Keep the transcripts before the repository goes. This runs
                # for a finished agent, a killed agent, and a failed step.
                try:
                    kept = keep_transcripts(work / "repo", outpath, instance_id)
                    if kept is not None:
                        log(f"{prefix} transcripts -> [bold]{kept}[/]")
                except OSError as exc:
                    log(f"{prefix} [yellow]transcripts not kept[/]: {exc}")
                shutil.rmtree(work, ignore_errors=True)

# --- the summary ------------------------------------------------------------
total_dt = time.monotonic() - t_all
log(
    f"[bold]complete[/] -- "
    f"[green]{counts['patches']} patches[/], "
    f"[yellow]{counts['empty']} empty[/], "
    f"[red]{counts['timeouts']} too slow[/], "
    f"[red]{counts['setup']} with no environment[/], "
    f"[red]{counts['errors']} errors[/], "
    f"[dim]{counts['skipped']} not done again[/] in {total_dt / 60:.1f} min"
)
log(f"get the score with: [bold]uv run bench/swebench_score.py {outpath}[/]")

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
    "no environment", f"[red]{counts['setup']}[/]" if counts["setup"] else "0"
)
table.add_row("errors", f"[red]{counts['errors']}[/]" if counts["errors"] else "0")
table.add_row("not done again", str(counts["skipped"]))
table.add_row("output", str(outpath))
table.add_row("next", f"uv run bench/swebench_score.py {outpath}")
table.add_row("wall time", f"{total_dt / 60:.1f} min")
console.print()
console.print(table)

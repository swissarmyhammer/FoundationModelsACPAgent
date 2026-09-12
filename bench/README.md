# bench — SWE-bench for `acp-agent`

[SWE-bench](https://www.swebench.com/) gives each agent a real GitHub issue
and a real repository. The agent must change the code. The official harness
then runs the tests of the project. An instance is **resolved** when the
tests pass.

This directory runs SWE-bench against the `acp-agent` binary of this package.

## Two steps

The work is two scripts, because the two steps fail in different ways.

| Step | Script | What it needs | What it makes |
|---|---|---|---|
| Make the patches | `swebench_run.py` | the agent, git, network | `preds.jsonl` |
| Give the score | `swebench_score.py` | docker | a score report |

The agent run is long. The docker run is short, but it can run out of memory.
So the predictions stay on disk, and you can score them again at any time.

## The command line

Do all of this from the root of the package, and not from this directory.

```bash
cd /path/to/FoundationModelsACPAgent

# 0. Build the agent. The scripts find this binary with no help.
swift build -c release

# 1. Make the patches. Start with 3, and keep a record.
uv run bench/swebench_run.py bench/preds.jsonl --limit 3 | tee bench/run.log

# 2. Give the score. Docker must run.
uv run bench/swebench_score.py bench/preds.jsonl
```

`uv` gets the Python dependencies of each script, at the versions the script
pins. There is nothing to install by hand.

**Write the results into `bench/`.** The `.gitignore` of this directory keeps
`preds*.jsonl`, `*.runs.jsonl`, `*.log`, the score reports, `*.transcripts/`
and `logs/` out of git. A results file at the root of the package is not
ignored, and it makes the working tree dirty.

**Each run records what each instance cost.** Beside the predictions, the run
writes `bench/preds.runs.jsonl` with one row for each instance. Read
[The record of a run](#the-record-of-a-run).

**Each instance keeps its agent transcripts.** The agent writes its session
transcripts into the temporary repository, and the run removes that
repository. So `swebench_run.py` copies them into
`bench/preds.transcripts/<instance_id>/` before the repository goes. Read them
to see each model round of an instance, for example to find why one round was
slow.

### One problem only

```bash
uv run bench/swebench_run.py bench/preds.jsonl -i psf__requests-2317 --verbose
uv run bench/swebench_score.py bench/preds.jsonl
```

`psf__requests-2317` is a good first choice: the repository is small, so the
clone and the docker image are both quick. `--verbose` puts the session
events of the agent on the console, so you can see what it does.

### If you do not build

The scripts look for the release build, then the debug build, then the PATH.
So a debug build works:

```bash
uv run bench/swebench_run.py bench/preds.jsonl --limit 3
```

But a debug build is much slower than a release build for MLX inference. For
a true number, build the release.

The first line of the output says which binary it found. Read it.

### The full split

```bash
uv run bench/swebench_run.py bench/preds.jsonl | tee bench/run.log
uv run bench/swebench_score.py bench/preds.jsonl
```

Measure the time of 3 instances on your machine before you do this. The
SWE-bench_Lite split is 300 instances.

### The options

Each script has `--help`. These are the options you will use:

| Option | Script | What it does |
|---|---|---|
| `--limit N` | run | the first N instances only |
| `-i ID ID` | run | these instance ids only |
| `--force` | run | do every instance again, and write over the file |
| `--agent PATH` | run | a different agent binary |
| `--timeout SECONDS` | run | the limit of one instance (default 3600) |
| `--verbose` | run | give `--verbose` to the agent |
| `--instance-ids ID` | score | score these ids only |
| `--max-workers N` | score | how many docker workers run together |

## What to expect

* **The limit of one instance is one hour** (`--timeout`). Three instances
  can thus be three hours. An agent that goes past the limit is stopped, but
  the run KEEPS the patch of that instance. Read
  [A patch that the watchdog stopped](#a-patch-that-the-watchdog-stopped).
* **The run continues.** The predictions file says which instances are done.
  If you stop the run with `Ctrl-C`, start the same command again and it
  continues. `--force` does them all again.
* **Each instance starts a new process.** So the agent loads its models
  again for each instance. This is minutes of each instance.
* **The first score of a repository builds a docker image.** This is slow,
  and it is emulated on Apple Silicon. Later instances of the same
  repository use the image again.

Each script writes its messages to standard output, and it makes no log
file. `| tee run.log` keeps a record of a long run.

The agent uses local models. Read the memory conditions in the
[README of the package](../README.md) first.

## What the agent gets

The agent gets the problem statement of the instance, and nothing more.

```
acp-agent run - --cwd <the cloned repository>
```

There is no skill, and there is no workflow, because this package has no
skills yet. This is the simple test. When skills come, a skill prompt can go
in front of the problem statement, and then you can compare the two numbers.

The prompt goes to the standard input of the agent. So no shell quote and no
argument length can change the text of the problem.

### A clean environment

The agent gets a clean environment, and not the environment of the harness.

`uv run` makes an ephemeral environment for `swebench_run.py`, and it sets
`VIRTUAL_ENV` and the first entries of `PATH` to that environment. A child
process that gets the same environment finds the Python of the HARNESS. In
the run of 2026-09-11 the agent found it, and it then tried to install
packages in the cache of `uv`. That work is not the task of the instance.

So `swebench_env.py` makes the environment of the agent:

* it removes `VIRTUAL_ENV`, every `UV_*` variable, `PYTHONPATH` and
  `PYTHONHOME`;
* it removes each `PATH` entry below the environment of the harness, and
  below the cache of `uv`;
* it keeps `HOME`, `USER`, `TMPDIR`, `LANG` and the directories of the
  system.

Each instance writes a log line with the Python that the agent gets:

```
09:12:31 the environment of the agent -- python3: /usr/bin/python3 . PATH: ...
```

### The tests of the harness

```bash
python3 -m unittest discover --start-directory bench --pattern 'test_*.py'
```

That command runs every test of this directory. One file runs alone too:

```bash
uv run bench/test_swebench_env.py
python3 bench/test_swebench_prediction.py
```

The tests of the environment start a real child process with that
environment, and they read what the process can see. The tests of the
prediction and of the record read the two rows that a run writes for each
instance. The tests of docker give the module a stand-in for
`subprocess.run`, so they start no daemon and they give the same answer on
each machine. All of them need the standard library only, so `python3` runs
them with no help. The `bench` job of CI runs
the discovery command on each push, so it finds a new `test_*.py` file with
no change to the workflow.

## How the patch is made

The patch is `git diff <base_commit>` in the cloned repository.

* It is **not** `git diff HEAD`. The agent can commit its change. A diff
  against the base commit finds the change in both conditions.
* It reports **tracked files only**. So the `.acp-agent` directory the agent
  writes, with its transcripts, is out of the patch. Never `git add -A`
  first: that puts the whole directory in the patch, and the harness then
  cannot apply it.

### A patch that the watchdog stopped

**The run keeps the patch in all conditions.** An agent that goes past the
time limit is stopped, and the row of that instance keeps the diff that the
tree held at that moment. The row carries one name more:

```json
{"instance_id": "...", "model_name_or_path": "...", "model_patch": "...", "truncated": true}
```

The predictions file is the durable record of a run. A row that holds the work
is better than a row that holds nothing, because you can score it again later.
So the run step keeps the work, and **the score step decides what to do with
it**: score the truncated rows with the others, or leave them out with
`--instance-ids`. Nothing is decided for you, and nothing is thrown away.

A stopped tree can hold the correct answer. In the run of 2026-09-11 the
watchdog stopped `astropy__astropy-14182` at the limit of one hour, and the
tree held the two correct files for that issue:

```
 M astropy/io/ascii/rst.py
 M astropy/io/ascii/tests/test_rst.py
```

The harness of that day recorded an empty patch, and the work was lost.

Two notes for a reader of the file:

* A row with no `truncated` name is a row of an agent that finished, or a row
  of a run before this change. So read the name with `get`, and not with `[]`.
* The summary of a run still counts the instances that went past the limit.
  The count is the `too slow` line of the table.

## The record of a run

A run writes `bench/preds.runs.jsonl` beside the predictions, with one row for
each instance it did. The predictions file says WHAT the agent made. This file
says what the instance COST.

```json
{"instance_id": "astropy__astropy-14182", "seconds": 3612.4, "clone_seconds": 24.1,
 "agent_seconds": 3584.2, "exit_code": -9, "timed_out": true, "patch_bytes": 1842,
 "patch_files": 2, "transcript_path": "bench/preds.transcripts/astropy__astropy-14182"}
```

| Field | What it is |
|---|---|
| `instance_id` | the instance |
| `seconds` | the wall time of the instance |
| `clone_seconds` | the time of the clone and the checkout |
| `agent_seconds` | the time of the agent process |
| `exit_code` | the exit code of the agent |
| `timed_out` | whether the watchdog stopped it |
| `patch_bytes` | the size of the patch |
| `patch_files` | the count of files in the patch |
| `transcript_path` | where the transcripts are |

Three notes for a reader of the file:

* **Each row carries all nine names.** A step that did not run gives `null`.
  An instance that failed in the clone thus has `null` for `clone_seconds`,
  `agent_seconds` and `exit_code`, and its row still has the same shape as
  every other row.
* **A row goes to disk when its instance ends.** A run of many hours can stop
  at any instance, and the rows of the instances that are complete stay.
* **An instance that failed also gets a row.** The count of the instances in
  this file is thus the count of the instances the run did.

Before this file, the durations went to standard output alone, and a run kept
them only if you added `| tee`. The run of 2026-09-11 kept no log, and to find
why the instances were slow all of the time data had to be built again from
the transcripts.

## What the score means

The score is **resolved / evaluated**, and not resolved / sent.

An instance that did not run, because docker could not build its image, is
reported alone. It is never part of the divisor. A memory failure is not an
agent failure. The score script does each such instance one more time,
alone, with a clean build, before it reports.

Each score run writes `preds.jsonl.score.<run id>.json` beside the
predictions, with the resolved, unresolved and errored ids.

### Docker must run, and the step proves it first

**The score step asks the daemon before it does any other work.** A daemon
that does not answer stops the step at once:

```
08:08:42 DOCKER_HOST -> unix:///Users/you/.docker/run/docker.sock
docker does not answer. The score step needs a docker daemon that runs,
because the SWE-bench harness builds an image for each instance.
the endpoint it tried: unix:///Users/you/.docker/run/docker.sock
start docker, and then give this command again.
```

The message names the endpoint, because that is the fact a person needs: a
daemon that is stopped and an endpoint that is wrong read the same way
without it.

The question is `docker info`, and not `docker context inspect`. The context
reads the configuration of docker, and it answers with a path although no
daemon runs. The score run of 2026-09-11 asked the context, pointed at a
socket that was not there, and wrote this:

```json
"submitted": 16, "evaluated": 0, "resolved": 0, "errored": [ ... all 16 ... ]
```

That report reads like a failure of the agent. Docker was the cause.

**A run that evaluated no instance writes no report.** No file is better than
a file that says `"resolved": 0` when the agent was never asked.

### The run id is a name

`--run-id` becomes part of two paths: the name of the report file, and the
directory of the logs of the harness. So a run id is a NAME: a letter or a
digit, and then letters, digits, dot, dash and underline. A run id such as
`../../etc/hostname` would write outside the directory of the predictions,
and the step refuses it before the harness starts:

```
the run id '../../etc/hostname' is not a name. A run id begins with a letter
or a digit, and after that it holds letters, digits, dot, dash and underline
only, because it becomes part of the path of the report.
```

### The exit codes of the score step

| Code | What it means |
|---|---|
| 0 | a score was made, and the report is beside the predictions |
| 2 | the command line is not valid: the predictions file is absent, it holds no instance to score, or the run id is not a name |
| 3 | the docker daemon does not answer |
| 4 | docker ran, and no instance was evaluated. There is no score |

## Files

```
swebench_run.py              makes preds.jsonl with the agent — read it top to bottom
swebench_score.py            gives the score of a preds.jsonl with docker
swebench_common.py           the console and the log line the two scripts share
swebench_env.py              the clean environment that the process of the agent gets
swebench_prediction.py       the prediction row that a run makes for one instance
swebench_record.py           the record row that a run makes for one instance
swebench_docker.py           the question that the score step asks docker first
swebench_report.py           the report that a score run writes, and when it does not
test_swebench_env.py         the tests of that environment
test_swebench_prediction.py  the tests of that prediction row
test_swebench_record.py      the tests of that record row
test_swebench_docker.py      the tests of that question to docker
test_swebench_report.py      the tests of that report
.gitignore                   keeps the run results out of git
```

## Where it came from

The two scripts started as the `sah` A/B harness in the `bench` repository of
the same organization. The parts that are the same are the repository setup,
the patch capture, and the docker score. The parts that changed are the agent
command, and the removal of the second arm.

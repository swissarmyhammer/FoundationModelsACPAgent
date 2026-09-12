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
| Make the patches | `swebench_run.py` | the agent, git, uv, network | `preds.jsonl` |
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
uv run bench/swebench_run.py bench/preds.jsonl --sample 3 | tee bench/run.log

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

The choice reads `-i` too. An id of the 121 instances that this machine cannot
build is left out, and the run says why. Add `--all` to do that instance.

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
| `--sample N` | run | a random sample of N instances, in the ratio of the split |
| `--seed S` | run | the seed of that sample (default 0), so a run can be done again |
| `--all` | run | do every instance, and not the 179 that run here |
| `--limit N` | run | the first N of the instances that are left |
| `-i ID ID` | run | these instance ids only |
| `--force` | run | do every instance again, and write over the file |
| `--agent PATH` | run | a different agent binary |
| `--timeout SECONDS` | run | the limit of one instance (default 3600) |
| `--oldest-python VERSION` | run | the Python to try for the instances that want 3.6 |
| `--verbose` | run | write one line for each session event of the agent |
| `--instance-ids ID` | score | score these ids only |
| `--max-workers N` | score | how many docker workers run together |

## What to expect

* **A run does 179 of the 300 instances.** This machine cannot build the
  other 121, so the run leaves them out before it starts and it says why.
  Read [Which instances a run does](#which-instances-a-run-does).
* **A short run is a fair sample.** `--sample 10` gives ten instances, with
  each repository in the ratio of the split. `--limit 10` gives the first ten
  of the split, which are astropy instances.
* **The limit of one instance is one hour** (`--timeout`). Three instances
  can thus be three hours. An agent that goes past the limit is stopped, but
  the run KEEPS the patch of that instance. Read
  [A patch that the watchdog stopped](#a-patch-that-the-watchdog-stopped).
* **The run continues.** The predictions file says which instances are done.
  If you stop the run with `Ctrl-C`, start the same command again and it
  continues. `--force` does them all again.
* **One agent process serves the whole run.** The models load one time, when
  the first instance starts. Read
  [One agent, and one session for each instance](#one-agent-and-one-session-for-each-instance).
* **The first score of a repository builds a docker image.** This is slow,
  and it is emulated on Apple Silicon. Later instances of the same
  repository use the image again.

Each script writes its messages to standard output, and it makes no log
file. `| tee run.log` keeps a record of a long run.

**A line is a message and its fields.** The message says what happened, and
each value stands after a name of its own:

```
09:12:31 done instance=django__django-11099 number=3 of=5 files=2 added=14 removed=3 seconds=812
```

A person reads that line, and a machine reads it too:
`grep instance=django__django-11099 run.log` gives the whole story of one
instance.

The agent uses local models. Read the memory conditions in the
[README of the package](../README.md) first.

## Which instances a run does

**A run does the instances this machine can build, and it leaves the others
out before it starts.** The dataset is in alphabetical order, so the old
`--limit 16` always gave the same 16 astropy and django instances. This
machine can build none of those 16: 12 want Python 3.6, and 4 need `apt-get`.
That run made no patch, and its numbers said nothing about the agent.

| Condition | Instances |
|---|---|
| The spec wants Python 3.6, and `uv` has no 3.6 and no 3.7 build for arm64 | 77 |
| The spec has a `pre_install`, which is written for linux | 44 |
| **The instances that run on this mac** | **179** |

The two groups do not intersect. Read
[What this machine cannot build](#what-this-machine-cannot-build) for the
reason of each group.

The run writes one line for each reason, with the count of its instances:

```
09:12:31 left out: this machine cannot build these instances instances=44 reason=the spec has a `pre_install`, and those commands are written for linux: `apt-get`, or a `sed -i` in the form of GNU
```

`--all` turns the choice off, and the run then does all 300 instances. Each
instance that does not build then gets a record row with `env_status` and
`env_reason`, and no prediction row.

### A fair sample

`--sample N` takes a random sample of N of the instances that are left, and it
gives each repository the places its size earns. django holds 114 of the 300
instances of the split, so it holds about 38 places of each 100 of a sample.

```bash
uv run bench/swebench_run.py bench/preds.jsonl --sample 10           # seed 0
uv run bench/swebench_run.py bench/preds.jsonl --sample 10 --seed 7
```

The seed is the whole state of the choice. The same seed gives the same
instances, so a run can be done again, and each run writes its seed in the
log. The default seed is 0.

The sample stays in the order of the split, so the log of a run reads in that
order. `--limit N` then takes the first N of the answer.

`swebench_select.py` makes the choice, and `test_swebench_select.py` holds the
proofs.

## One agent, and one session for each instance

The run started `acp-agent run` for each instance. The agent resolves its
profile and loads its local models when it starts, so a run of 179 instances
loaded them 179 times. That is minutes of each instance, and hours of a run.

So the harness is the CLIENT of `acp-agent acp` now. It starts ONE process
for the whole run, and it drives the wire itself:

```
start `acp-agent acp`  ---------->  load the models (ONE time)
initialize             ---------->
for each instance:
  session/new(cwd)     ---------->  a session in the clone of the instance
  session/prompt       ---------->  {} at once
                       <----------  session/update ... (the whole turn)
                       <----------  session/update: idle, stopReason
  session/close        ---------->  free the tree of that instance
```

`swebench_acp.py` speaks that wire, and its module comment says how.

**The wire gives the STOP REASON of each turn.** `end_turn`, `max_tokens`,
`max_turn_requests`, `refusal`, `cancelled`, and the `_error`, `_no_output`
and `_stalled` of this agent. The one-shot `run` command gave the harness an
exit code and nothing more. The record of the instance keeps the reason.

**A turn past the limit gets `session/cancel`,** and not a signal. The agent
answers with the `cancelled` stop reason, and the run goes on with the same
process. A process that does not answer is stopped, and the instance after it
gets a new one.

**`--verbose` reads those session events HERE.** `acp-agent acp` takes no
option of its own, because it writes the events of a session to its client.

### What the agent gets

The agent gets the problem statement of the instance, and nothing more. There
is no skill, and there is no workflow, because this package has no skills
yet. This is the simple test. When skills come, a skill prompt can go in
front of the problem statement, and then you can compare the two numbers.

The prompt goes over the wire as one text content block. So no shell quote
and no argument length can change the text of the problem.

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
09:12:31 the environment of the agent instance=django__django-11099 number=3 of=5 python3=/usr/bin/python3 PATH=...
```

## The environment of the instance

**The run builds the Python environment of each instance, before the agent
starts.** A SWE-bench repository does not import from a source checkout, so
without this step the agent cannot run one test of the instance.

In the run of 2026-09-11 the agent had to do that work itself, and it was the
largest cost of the run: 219 of 707 tool calls were about pip, uv, virtual
environments or absent modules. For `astropy__astropy-6938` it was 37 of 80
calls, and the agent never got a working environment. Its transcripts hold
lines such as:

```
ModuleNotFoundError: No module named 'erfa'
ImportError: You appear to be trying to import astropy from within a source
checkout
```

So `swebench_venv.py` does it now. For each instance it:

* reads the environment of that repository and version from
  `MAP_REPO_VERSION_TO_SPECS`, which the `swebench` package publishes;
* makes `<clone>/.venv` with `uv venv --seed --python <the version of the
  spec>`;
* installs the `pip_packages` of the spec with the Python of that
  environment;
* installs the requirements file of the repository, when the spec names one.
  The file is NOT `requirements.txt` at the root: `MAP_REPO_TO_REQS_PATHS`
  says where it stands, and django keeps its file at
  `tests/requirements/py3.txt`. The clone already holds it, so this asks for
  no network;
* runs the `install` command of the spec, for example
  `python -m pip install -e .`;
* puts `<clone>/.venv/bin` FIRST on the `PATH` of the agent.

Django builds in 12 seconds this way, and `./tests/runtests.py` then runs in
the clone with no more work.

**The clone of every instance stands at the same path.** The run makes ONE
working root, and the clone is always `<root>/repo`. So `<root>/repo/.venv/bin`
is a constant entry of the PATH, and the one agent process gets it when it
starts.

That is necessary, and not a convenience. The agent gives each shell child
the whole environment of its own PROCESS, with the arguments of the tool call
on top. There is no environment for each session, and the agent reads no
`.venv` below a session directory. So a PATH that changed with the instance
could not reach the tests of the instance.

Each instance removes the clone and clones again into the same path. Nothing
of one instance reaches the next one: the agent builds the configuration, the
instructions, the `AGENTS.md` assembly, the tool catalog and the sandbox
again at every `session/new`, from the directory of THAT session.

**Each path of the published table stands in the clone.**
`MAP_REPO_TO_REQS_PATHS` comes from the `swebench` package, and each path of it
becomes a path of this machine. So `swebench_venv.py` has one gate,
`checked_clone_path`, and every path goes through it. A path with a `..` part,
or an absolute path, would name a file OUTSIDE the clone, and the step refuses
it:

```
the path '../../etc/hostname' of the published table does not stand in the
clone /var/folders/.../repo. A path of that table names a file OF the
repository, so it is relative to the clone and it holds no `..` part.
```

### What this machine cannot build

The agent uses local models, so it runs on the mac and not in a linux
container. Two groups of the Lite split do not build here: 77 instances want
Python 3.6, which `uv` does not build for arm64, and 44 instances have a
`pre_install`, which is written for linux. The table of the counts stands in
[Which instances a run does](#which-instances-a-run-does), and a run leaves
both groups out before it starts.

A `pre_install` holds `apt-get`, or a `sed -i 's/x/y/' file` in the form of GNU
that the `sed` of macOS does not accept, so no option answers that group.
`--oldest-python 3.8` gives the first group a Python to try, and the record of
each instance then says which Python it got.

**An instance that does not build gets NO prediction row.** A failed
environment is not a failure of the agent, and it must not be part of the
score. The instance gets a record row with `env_status` and `env_reason`, so
a reader of the run knows why it was left out. A later run does that instance
again, because the predictions file is what says which instances are done.

### The tests of the harness

```bash
python3 -m unittest discover --start-directory bench --pattern 'test_*.py'
```

That command runs every test of this directory. One file runs alone too:

```bash
uv run bench/test_swebench_env.py
python3 bench/test_swebench_prediction.py
```

The tests of the clean environment start a real child process with that
environment, and they read what the process can see. The tests of the
prediction and of the record read the two rows that a run writes for each
instance. The tests of docker and of the environment of an instance give the module a
stand-in for `subprocess.run`, so they start no daemon, they make no virtual
environment, and they give the same answer on each machine. That stand-in
stands in `test_fixtures.py`, so there is one copy of it. The tests of the
choice give the module a table of specs of their own, so they read no dataset
and no published table. The tests of the
long-lived agent give the client a stand-in wire with a script of answers, so
they start no agent, they load no model and they open no pipe. All of them need the standard library only, so `python3` runs
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
 "agent_seconds": 3584.2, "exit_code": null, "stop_reason": "cancelled",
 "timed_out": true, "patch_bytes": 1842,
 "patch_files": 2, "transcript_path": "bench/preds.transcripts/astropy__astropy-14182",
 "env_status": "built", "env_python": "3.9", "env_seconds": 61.5,
 "env_exit_code": null, "env_reason": null}
```

| Field | What it is |
|---|---|
| `instance_id` | the instance |
| `seconds` | the wall time of the instance |
| `clone_seconds` | the time of the clone and the checkout |
| `agent_seconds` | the time of the turn of the agent |
| `exit_code` | the exit code of an agent process that ENDED in this instance |
| `stop_reason` | why the agent stopped the turn |
| `timed_out` | whether the watchdog stopped it |
| `patch_bytes` | the size of the patch |
| `patch_files` | the count of files in the patch |
| `transcript_path` | where the transcripts are |
| `env_status` | what the environment step did: `built`, `failed` or `unsupported` |
| `env_python` | the Python version of the environment |
| `env_seconds` | the time of the environment step |
| `env_exit_code` | the exit code of the build command that failed |
| `env_reason` | why the instance did not run |

Three notes for a reader of the file:

* **Each row carries all fifteen names.** A step that did not run gives
  `null`. An instance that failed in the clone thus has `null` for
  `clone_seconds`, `agent_seconds` and `stop_reason`, and its row still has
  the same shape as every other row.
* **`exit_code` is `null` for almost every row.** One process serves the
  whole run, so an instance that ended with the agent alive has no exit code
  of its own. The name holds the code of a process that DIED in that
  instance.
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
swebench_event.py            the shape of one line: a message and its fields
swebench_acp.py              the one long-lived agent of a run, over ACP
swebench_env.py              the clean environment that the process of the agent gets
swebench_prediction.py       the prediction row that a run makes for one instance
swebench_record.py           the record row that a run makes for one instance
swebench_venv.py             the Python environment that a run builds for one instance
swebench_select.py           which instances a run does, and the fair sample
swebench_docker.py           the question that the score step asks docker first
swebench_report.py           the report that a score run writes, and when it does not
test_swebench_acp.py         the tests of that agent and that wire
test_swebench_env.py         the tests of that environment
test_swebench_prediction.py  the tests of that prediction row
test_swebench_record.py      the tests of that record row
test_swebench_venv.py        the tests of that environment
test_swebench_select.py      the tests of that choice and that sample
test_swebench_docker.py      the tests of that question to docker
test_swebench_report.py      the tests of that report
test_swebench_event.py       the tests of that line
test_fixtures.py             the stand-in for subprocess.run that the tests share
.gitignore                   keeps the run results out of git
```

## Where it came from

The two scripts started as the `sah` A/B harness in the `bench` repository of
the same organization. The parts that are the same are the repository setup,
the patch capture, and the docker score. The parts that changed are the agent
command, and the removal of the second arm.

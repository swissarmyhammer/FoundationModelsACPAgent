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
`preds*.jsonl`, `*.log`, the score reports, `*.transcripts/` and `logs/` out of
git. A results file at the root of the package is not ignored, and it makes
the working tree dirty.

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
  can thus be three hours. An agent that goes past the limit is stopped, and
  the harness records an empty patch: a half-written repository is not an
  answer.
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

## How the patch is made

The patch is `git diff <base_commit>` in the cloned repository.

* It is **not** `git diff HEAD`. The agent can commit its change. A diff
  against the base commit finds the change in both conditions.
* It reports **tracked files only**. So the `.acp-agent` directory the agent
  writes, with its transcripts, is out of the patch. Never `git add -A`
  first: that puts the whole directory in the patch, and the harness then
  cannot apply it.

## What the score means

The score is **resolved / evaluated**, and not resolved / sent.

An instance that did not run, because docker could not build its image, is
reported alone. It is never part of the divisor. A memory failure is not an
agent failure. The score script does each such instance one more time,
alone, with a clean build, before it reports.

Each score run writes `preds.jsonl.score.<run id>.json` beside the
predictions, with the resolved, unresolved and errored ids.

## Files

```
swebench_run.py     makes preds.jsonl with the agent — read it top to bottom
swebench_score.py   gives the score of a preds.jsonl with docker
swebench_common.py  the console and the log line the two scripts share
.gitignore          keeps the run results out of git
```

## Where it came from

The two scripts started as the `sah` A/B harness in the `bench` repository of
the same organization. The parts that are the same are the repository setup,
the patch capture, and the docker score. The parts that changed are the agent
command, and the removal of the second arm.

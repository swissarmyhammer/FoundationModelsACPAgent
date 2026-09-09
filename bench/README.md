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

## How to use it

```bash
# 0. Build the agent. The scripts find this binary without help.
swift build -c release

# 1. Make the patches. Start with a few.
uv run bench/swebench_run.py preds.jsonl --limit 3

# 2. Give the score. Docker must run.
uv run bench/swebench_score.py preds.jsonl
```

`uv` gets the Python dependencies of each script. There is nothing to install
by hand. Each script has `--help`.

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

## What it costs

The agent uses local models, and it is slow. Read the memory conditions in
the [README of the package](../README.md) first.

* **Each instance starts a new process.** So the agent loads its models
  again for each instance. This is minutes of each instance.
* **The limit of one instance is one hour** (`--timeout`). An agent that goes
  past the limit is stopped, and the harness records an empty patch. A
  half-written repository is not an answer.
* **The first score of a repository builds a docker image.** This is slow.
  Later instances of the same repository use the image again.

Start with `--limit 3`, and measure the time on your machine before you run
the full split.

## How the patch is made

The patch is `git diff <base_commit>` in the cloned repository.

* It is **not** `git diff HEAD`. The agent can commit its change. A diff
  against the base commit finds the change in both conditions.
* It reports **tracked files only**. So the `.acp-agent` directory the agent
  writes, with its transcripts, is out of the patch. Never `git add -A`
  first: that puts the whole directory in the patch, and the harness then
  cannot apply it.

## Files

```
swebench_run.py     makes preds.jsonl with the agent — read it top to bottom
swebench_score.py   gives the score of a preds.jsonl with docker
.gitignore          keeps the run results out of git
```

## Where it came from

The two scripts started as the `sah` A/B harness in the `bench` repository of
the same organization. The parts that are the same are the repository setup,
the patch capture, and the docker score. The parts that changed are the agent
command, and the removal of the second arm.

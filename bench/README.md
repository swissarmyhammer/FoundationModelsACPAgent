# bench — SWE-bench for `acp-agent`

This directory runs [SWE-bench](https://www.swebench.com/) Lite against the
`acp-agent` binary of this package. The agent gets a real issue and a real
repository, and it must change the code. An instance is **resolved** when the
tests of the project pass.

The work has two steps, because the two steps fail in different ways:

| Step | Script | Needs | Makes |
|---|---|---|---|
| Make the patches | `swebench_run.py` | the agent, git, uv, network | `preds.NAME.jsonl` |
| Give the score | `swebench_score.py` | docker | a score report |

To watch a run and find its problems, use the `swebench` skill:
[`.claude/skills/swebench/SKILL.md`](../.claude/skills/swebench/SKILL.md).
To score a run and compare runs, use the `swebench-score` skill:
[`.claude/skills/swebench-score/SKILL.md`](../.claude/skills/swebench-score/SKILL.md).

## Run it

Run the commands from the root of the package. `uv` gets the Python
dependencies of each script. Give each run its own NAME.

```bash
swift build -c release
# N instances: the first N that are left
uv run bench/swebench_run.py bench/preds.NAME.jsonl --limit 3 2>&1 | tee bench/run.NAME.log
# One instance (or more: -i ID ID ...)
uv run bench/swebench_run.py bench/preds.NAME.jsonl -i psf__requests-2317 2>&1 | tee bench/run.NAME.log
```

`2>&1` is necessary, because an interrupt or a Python error goes to standard
error. After a new commit of a sibling package, run `swift package update`
before the build. The scripts use the release build, then the debug build,
then `PATH`; the first line of the log names the binary.

| Option | What it does |
|---|---|
| `--limit N` | the first N of the instances that are left |
| `-i ID ...` | these instance ids only (this replaces `--limit`) |
| `--sample N`, `--seed S` | a random sample of N, in the ratio of the split (seed default 0) |
| `--timeout SECONDS` | the limit of one instance (default 3000) |
| `--agent-config FILE` | a `config.yaml` for the agent, copied into each clone as `.acp-agent/config.yaml` |
| `--force` | do every instance again, and write over the predictions |
| `--all` | also the instances that this machine cannot build |
| `--oldest-python VERSION` | the Python to try for an instance that wants 3.6 |
| `--agent PATH` | a different agent binary |
| `--verbose` | one log line for each session event of the agent |

Each script has `--help` for the full list.

### The code context with skills run

Add `--agent-config bench/code-context.config.yaml`, and use the NAME
`code-context`. The agent then mounts the `code-context` branch of the skills
marketplace, the `tools.code_context` group, and the `tools.web` group.

Web search needs no key. With no key, the search uses the free public pages of
Brave and DuckDuckGo. A key is optional: `BRAVE_SEARCH_API_KEY`,
`TAVILY_API_KEY`, `EXA_API_KEY`, `SERPER_API_KEY`, `KAGI_API_KEY` or
`SEARXNG_URL`. **A web search can find the upstream fix of the issue.** Thus
the score of a run with web on does not measure the agent alone.

## What a run does

- It does 179 of the 300 instances. 77 want Python 3.6, which `uv` does not
  build for arm64, and 44 have a `pre_install` for linux. `--all` does all 300.
- It continues after a stop. Give the same command again: the predictions
  file says which instances are done.
- One `acp-agent acp` process serves the whole run. Each instance gets its own
  session in a new clone, and an instance past the time limit gets
  `session/cancel`.
- It builds `<clone>/.venv` for each instance before the agent starts, and
  puts `.venv/bin` first on the `PATH` of the agent.
- The patch is `git diff <base_commit>` of the tracked files. The patch of a
  stopped instance is kept, with `"truncated": true`.

## Outputs

All outputs go into `bench/`, where `.gitignore` keeps them out of git.

| File | What it holds |
|---|---|
| `preds.NAME.jsonl` | one prediction row for each instance that got an environment |
| `preds.NAME.runs.jsonl` | one record row for each instance: times, `stop_reason`, `timed_out`, patch size, environment step, `agent_config` (see `swebench_record.py`) |
| `preds.NAME.transcripts/<instance_id>/` | the agent transcripts, copied when the instance ends |
| `run.NAME.log` | the log; `grep instance=<id>` gives the history of one instance |
| `preds.NAME.jsonl.score.<run id>.json` | the score report |

## The score

```bash
uv run bench/swebench_score.py bench/preds.NAME.jsonl
```

The score is **resolved / evaluated**. An instance that docker could not build
is in a group of its own, and it is not part of the divisor. The report has
the counts `submitted`, `evaluated`, `resolved`, `unresolved` and `errored`,
and the ids in `resolved_ids`, `unresolved_ids` and `errored_ids`. A report
from before 2026-09-12 has a list at `errored`; in such a report, read
`errored_ids`. Use
`--instance-ids ID ...` to score some ids only, `--max-workers N` for the
docker workers, and `--run-id NAME` for the name of the report.

| Exit code | What it means |
|---|---|
| 0 | a score was made |
| 2 | the command line is not valid |
| 3 | the docker daemon does not answer |
| 4 | docker ran, and no instance was evaluated |

## The skill trigger gate

A SWE-bench run takes hours to show that the model loaded no skill. This gate
shows it in about 20 seconds. CI runs it on each push:

```bash
swift test --package-path IntegrationTests --filter SkillTriggerTests
```

`ACP_AGENT_SKILL_TRIGGER_SAMPLES=understand-parser,release-notes` runs the
slower samples. `ACP_AGENT_SKILL_TRIGGER_MODEL` and
`ACP_AGENT_SKILL_TRIGGER_REPEATS` set the model and the number of runs.

## The tests of the harness

```bash
python3 -m unittest discover --start-directory bench --pattern 'test_*.py'
```

The tests use only the standard library. They start no agent and no docker
daemon. The `bench` job of CI runs them on each push.

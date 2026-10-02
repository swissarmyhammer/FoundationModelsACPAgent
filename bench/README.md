# bench — SWE-bench for `acp-agent`

This directory runs [SWE-bench](https://www.swebench.com/) Lite against the
`acp-agent` binary of this package. The agent gets a real issue and a real
repository, and it must change the code. An instance is **resolved** when the
tests of the project pass.

The work has two steps, because the two steps fail in different ways:

| Step | Script | Needs | Makes |
|---|---|---|---|
| Make the patches | `swebench_run.py` | the agent, git, uv, network | `preds.jsonl` |
| Give the score | `swebench_score.py` | docker | a score report |

## Run it

Run the commands from the root of the package. `uv` gets the Python
dependencies of each script.

```bash
swift build -c release
uv run bench/swebench_run.py bench/preds.jsonl --sample 3 2>&1 | tee bench/run.log
uv run bench/swebench_score.py bench/preds.jsonl
```

- **One instance:** use `-i psf__requests-2317 --verbose`. That repository is
  small, and `--verbose` shows the session events of the agent.
- **The code context with skills run:** add
  `--agent-config bench/code-context.config.yaml`, and give the run its own
  predictions file, for example `bench/preds.code-context.jsonl`. The run
  writes that file into each clone as `.acp-agent/config.yaml`. The agent
  then mounts the `code-context` branch of the skills marketplace and the
  `tools.code_context` group.
- **A new commit of a sibling package:** run `swift package update` before the
  build. `swift build` alone keeps the pinned revisions.
- **The binary:** the scripts look for the release build, then the debug
  build, then `PATH`. The first line of the output names the binary that
  they found.

Write the results into `bench/`, where `.gitignore` keeps them out of git.
`2>&1` is necessary, because an interrupt or a Python error goes to standard
error.

## Options

Each script has `--help`. These are the options that you will use:

| Option | Script | What it does |
|---|---|---|
| `--sample N` | run | a random sample of N instances, in the ratio of the split |
| `--seed S` | run | the seed of the sample (default 0) |
| `--limit N` | run | the first N of the instances that are left |
| `-i ID ...` | run | these instance ids only |
| `--all` | run | also the instances that this machine cannot build |
| `--force` | run | do every instance again |
| `--timeout SECONDS` | run | the limit of one instance (default 3000) |
| `--agent PATH` | run | a different agent binary |
| `--agent-config FILE` | run | a `config.yaml` for the agent in each clone |
| `--oldest-python VERSION` | run | the Python to try for an instance that wants 3.6 |
| `--verbose` | run | one line for each session event of the agent |
| `--instance-ids ID ...` | score | score these ids only |
| `--max-workers N` | score | how many docker workers run together |

## What a run does

- **It does 179 of the 300 instances.** It leaves out the others before it
  starts, and it gives the reason: 77 want Python 3.6, which `uv` does not
  build for arm64, and 44 have a `pre_install` that is written for linux.
  `--all` does all 300.
- **It continues after a stop.** The predictions file says which instances
  are done. Give the same command again. `--force` does them all again.
- **One agent process serves the whole run.** The harness is a client of
  `acp-agent acp`. The models load one time, and each instance gets its own
  session. An instance that goes past the time limit gets `session/cancel`.
- **It builds the Python environment of each instance before the agent
  starts.** The environment is `<clone>/.venv`, from the spec of the
  `swebench` package. The `.venv/bin` folder is first on the `PATH` of the
  agent. The agent also gets a clean environment, without the variables of
  the harness.
- **The patch is `git diff <base_commit>`** of the tracked files. The patch of
  an instance that the watchdog stopped is kept, with `"truncated": true`.
- **It keeps the transcripts** of each instance in
  `bench/preds.transcripts/<instance_id>/`.

Each line of the output is a message and its fields, so that `grep
instance=<id> run.log` gives the whole history of one instance:

```
09:12:31 done instance=django__django-11099 number=3 of=5 files=2 added=14 removed=3 seconds=812
```

### The record of a run

Beside the predictions, the run writes `bench/preds.runs.jsonl`, with one row
for each instance. Each row has the same fields. A step that did not run gives
`null`.

| Field | What it is |
|---|---|
| `seconds`, `clone_seconds`, `agent_seconds`, `env_seconds` | the wall time of the instance and of each step |
| `stop_reason` | why the agent stopped the prompt, for example `end_turn`, `cancelled`, `_truncated`, `_ended_in_reasoning`, `_repeated` or `_reasoning_limit` (a pass reasoned past `repetition.reasoningTokenLimit`, and no recovery was left) |
| `timed_out` | whether the watchdog stopped the agent |
| `exit_code` | the exit code of an agent process that ended in this instance; usually `null` |
| `patch_bytes`, `patch_files` | the size of the patch |
| `transcript_path` | where the transcripts are |
| `env_status`, `env_python`, `env_exit_code`, `env_reason` | what the environment step did: `built`, `failed` or `unsupported`, and why |

An instance whose environment did not build gets a record row, but no
prediction row. Thus it is not part of the score.

### Did the model use the tools?

A tool that the agent mounts is not always a tool that the model uses. Read
the transcripts before you read the score. In
`<id>/<session>/transcript.jsonl`:

- a call with `"toolName": "skills"` and `use skill` loaded a skill;
- `tools.code_context.` in the arguments of a `runCode` call is a code context
  call;
- a `"kind": "instructions"` line shows the tools that the model was offered.

## The score

The score is **resolved / evaluated**. An instance that docker could not build
is reported in a group of its own, and it is not part of the divisor. Each
score run writes `preds.jsonl.score.<run id>.json` beside the predictions,
with the counts `submitted`, `evaluated`, `resolved`, `unresolved` and
`errored`, and the ids of each group in `resolved_ids`, `unresolved_ids` and
`errored_ids`. A report from before 2026-09-12 has a list at `errored`. In
such a report, read `errored_ids`.

The score step runs `docker info` first, and it stops if docker does not
answer. `--run-id` must be a name: letters, digits, dot, dash and underscore.

| Exit code | What it means |
|---|---|
| 0 | a score was made |
| 2 | the command line is not valid |
| 3 | the docker daemon does not answer |
| 4 | docker ran, and no instance was evaluated |

## The skill trigger gate

A SWE-bench run takes hours to show that the model loaded no skill. The skill
trigger gate shows it in about 20 seconds, on the shipped standard model.
CI runs the gate on every push:

```bash
swift test --package-path IntegrationTests --filter SkillTriggerTests
```

`ACP_AGENT_SKILL_TRIGGER_SAMPLES=understand-parser,release-notes` runs the
slower samples, where the task does not ask for a skill.
`ACP_AGENT_SKILL_TRIGGER_MODEL` and `ACP_AGENT_SKILL_TRIGGER_REPEATS` set the
model and the number of runs. With the shipped model, greedy, on
2026-09-21: `understand-parser` loaded its skill after 198 s, and
`release-notes` after 201 s.

## The tests of the harness

```bash
python3 -m unittest discover --start-directory bench --pattern 'test_*.py'
```

The tests use only the standard library. They start no agent and no docker
daemon. The `bench` job of CI runs this command on each push.

## Files

| File | What it holds |
|---|---|
| `swebench_run.py` | makes `preds.jsonl` with the agent |
| `swebench_score.py` | gives the score of a predictions file with docker |
| `swebench_acp.py` | the one long-lived agent of a run, over ACP |
| `swebench_select.py` | which instances a run does, and the sample |
| `swebench_venv.py` | the Python environment of one instance |
| `swebench_env.py` | the clean environment of the agent process |
| `swebench_prediction.py`, `swebench_record.py` | the two rows of each instance |
| `swebench_docker.py`, `swebench_report.py` | the docker check and the score report |
| `swebench_common.py`, `swebench_event.py` | the console and the log line |
| `test_*.py`, `test_fixtures.py` | the tests, and their shared stand-in for `subprocess.run` |
| `code-context.config.yaml` | the agent configuration of the code context run |

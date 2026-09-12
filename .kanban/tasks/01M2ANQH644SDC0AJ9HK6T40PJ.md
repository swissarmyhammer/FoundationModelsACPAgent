---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2apgnjrppma0k3252371y77
  text: |-
    Picked up. Research:

    - `stream_agent` in `bench/swebench_run.py` calls `subprocess.Popen(cmd, cwd=cwd, ...)` with no `env=`, so the agent gets the environment of the harness. This is the only process that runs the agent.
    - `bench/` holds three Python files: two scripts with a PEP 723 block (`swebench_run.py`, `swebench_score.py`) and one module with no block (`swebench_common.py`). The module is the pattern for code that a test can import.
    - `swebench_run.py` cannot be imported in a test: the module body parses the arguments, finds the binary, and loads the dataset from huggingface. So the new code goes in a module of its own, `swebench_env.py`, which the script imports. The follow-on card ^m3fdcvh (the instance environment) puts `<repo>/.venv/bin` first on the PATH of the agent, and that work belongs in the same module.
    - The transcripts of 2026-09-11 confirm the evidence: `grep -rl environments-v2 bench/preds.transcripts` names 5 instances.
    - CI: `.github/workflows/ci.yml` delegates to the shared swift-ci workflow, and `CIWorkflowTests` pins that file to one job with no `steps:`. No test reads the directory of the workflows, so a new workflow file for the bench test does not break that pin. The test-partitioning rule says each test target must run in a CI task, so the new Python test gets its own small workflow.
  timestamp: 2026-09-12T11:37:18.168833+00:00
- actor: claude-code
  id: 01m2aqexhfgxh1e534y4fqhb3t
  text: |-
    Implementation landed.

    What the change does:
    - `bench/swebench_env.py` (new) makes the environment of the agent. It removes `VIRTUAL_ENV`, `PYTHONPATH`, `PYTHONHOME` and every `UV_*` variable, it removes each PATH entry below the virtual environment of the harness or below the cache of `uv`, and it removes an empty PATH entry, which names the directory of work. Each other variable stays, so the agent keeps `HOME`, `USER`, `TMPDIR` and `LANG`. When the harness holds every PATH entry, the agent gets `/usr/bin:/bin:/usr/sbin:/sbin`.
    - `stream_agent` in `bench/swebench_run.py` makes that environment and gives it to `subprocess.Popen` with `env=`. It writes one log line first: `the environment of the agent -- python3: <path> . PATH: <path>`.
    - `bench/test_swebench_env.py` (new) holds 12 tests. Five of them start a REAL child process with that environment and read what the process can see. A dictionary alone does not prove what a process gets.
    - `.github/workflows/bench.yml` (new) runs those tests on each push and each pull request. The tests need the standard library only, so the job installs nothing. `ci.yml` is not touched, and the 10 tests of `CIWorkflowTests` still pass.
    - `bench/README.md` and the docstrings of `swebench_run.py` say what the agent keeps and what it loses. `bench/.gitignore` now holds `__pycache__/`, because a script that imports a module of this directory makes it.

    Proof:
    - The tests fail against the earlier behaviour. With `agent_environment` changed to `dict(parent)` and `agent_path` to the PATH of the parent, 10 of the 12 tests fail. The other two measure the log line.
    - Below a real `uv run --script` harness, the agent environment loses exactly `VIRTUAL_ENV` and `UV_RUN_RECURSION_DEPTH`, and no value of it names the cache of `uv`.
    - A short run of `psf__requests-2317` with `--timeout 600` makes transcripts with ZERO references to `environments-v2` or `.cache/uv`. That run reached the 600 second limit, which is the instance limit that card ^n1bw41e measures again.

    For the next agent, on card ^m3fdcvh (the instance environment): `stream_agent` makes the environment itself and takes no environment parameter, as this card says. To put `<repo>/.venv/bin` first on the PATH, give `swebench_env` a function that adds a directory in front, and give `stream_agent` the directory of the instance.

    A discovery: `uv` does not put every ephemeral environment below `environments-v2`. This machine made `~/.cache/uv/builds-v0/.tmpGGLqJH`. So the code drops the entries below the CACHE of `uv`, and not the entries below one directory of it.
  timestamp: 2026-09-12T11:53:49.359705+00:00
- actor: claude-code
  id: 01m2aqf0zwy9nbk5ejxxwer0wm
  text: |-
    ### implement — changed
    - evidence: 6 files — bench/swebench_env.py (new), bench/test_swebench_env.py (new), bench/swebench_run.py (stream_agent: `env=environment` on Popen, the log line, the docstrings), bench/README.md, bench/.gitignore, .github/workflows/bench.yml (new). `python3 bench/test_swebench_env.py`: 12 tests, 0 failures. `swift test --filter CIWorkflowTests`: 10 tests, 0 failures.
    - next: /review
  timestamp: 2026-09-12T11:53:52.892415+00:00
- actor: claude-code
  id: 01m2ar2s11xyt76psbaz9skcdw
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 99e40b8). 0 findings, 0 confirmed, 1 refuted, 8 attempted, 0 failed. The engine read the 4 files of the change that a validator matches: `bench/swebench_env.py`, `bench/test_swebench_env.py`, `bench/swebench_run.py`, `.github/workflows/bench.yml`. No validator matches `bench/README.md` and `bench/.gitignore`. An ignore rule holds the 18 files of `.kanban/`. The description has no earlier finding to check.
    - next: none. The task moves to done.
  timestamp: 2026-09-12T12:04:40.097961+00:00
- actor: claude-code
  id: 01m2ar3f99c5bsyzc80k19w06y
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files: bench/swebench_env.py (new), bench/test_swebench_env.py (new), .github/workflows/bench.yml (new), bench/swebench_run.py, bench/README.md, bench/.gitignore
    - test: green — swift test 561 passed in 60 suites, 0 failed, 0 skipped; python3 bench/test_swebench_env.py 12 passed
    - commit: 99e40b8 — 24 files, local only, not pushed
    - review: clean — 0 findings, 1 refuted, 8 attempted, scope HEAD~1..HEAD
    - next: none, the task is in done
  timestamp: 2026-09-12T12:05:02.889367+00:00
position_column: done
position_ordinal: d380
title: 'bench: give the agent a clean environment, not the harness one'
---
## The problem

`stream_agent` in `bench/swebench_run.py` starts the agent with
`subprocess.Popen(cmd, cwd=cwd, ...)` and gives no `env=`. So the agent gets
the environment of the harness. The harness starts with
`#!/usr/bin/env -S uv run --script`, thus `VIRTUAL_ENV` and `PATH` point at the
ephemeral environment of the script.

The transcripts of the run of 2026-09-11 show what the agent then does. It
found the Python of the harness and tried to use it:

```
/Users/wballard/.cache/uv/environments-v2/swebench-run-296e9fecef83dd53/bin/python: No module named pip
```

The agent also examined that directory, tried to install packages into it, and
one time did `find / -name 'erfa*' -maxdepth 8` across the full disk.

## The work

1. Make the environment of the agent in `stream_agent`, and give it with
   `env=`.
2. Remove `VIRTUAL_ENV`, `UV_*`, `PYTHONPATH`, `PYTHONHOME` and the `PATH`
   entries of the harness.
3. Keep `HOME`, `USER`, `TMPDIR`, `LANG` and the system `PATH`.
4. Write the environment of the instance in the log line, so a run tells you
   which Python the agent gets.

## When it is complete

- The agent cannot see the environment of the harness.
- A test shows that `VIRTUAL_ENV` is absent in the process of the agent.
- A short run makes no reference to `~/.cache/uv/environments-v2/` in the
  transcripts.

Related: [[bench-prepare-the-instance-environment]] #bench
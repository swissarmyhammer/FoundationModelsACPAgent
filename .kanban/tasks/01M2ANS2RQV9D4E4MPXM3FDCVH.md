---
assignees:
- claude-code
depends_on:
- 01M2ANQH644SDC0AJ9HK6T40PJ
position_column: todo
position_ordinal: '8580'
title: 'bench: prepare the instance environment in the driver'
---
## The problem

`bench/swebench_run.py` does four steps for each instance: clone, checkout the
base commit, `git clean -fdx`, and start the agent. It builds no Python
environment. A SWE-bench repository does not import from a source checkout, so
the agent must build the environment itself.

In the run of 2026-09-11 this was the largest cost. Of 707 `runCode` calls,
219 (31%) were about pip, uv, virtual environments, `PYTHONPATH` or absent
modules. For `astropy__astropy-6938` it was 37 of 80 calls, and the last such
call was number 78 of 80. The agent never got a working environment.

Both instances that went past the one-hour limit died in this work. Their
transcripts show:

```
ModuleNotFoundError: No module named 'erfa'
ModuleNotFoundError: No module named 'numpy'
ImportError: cannot import name '_compiler' from 'astropy.utils'
ImportError: You appear to be trying to import astropy from within a source checkout
```

One instance wrote `astropy/io/fits/_utils.py` by hand, to take the place of a
compiled extension that was absent. That is not a fix.

## The data you need is already published

The official package holds the environment of each instance:

```python
from swebench.harness.constants import MAP_REPO_VERSION_TO_SPECS
spec = MAP_REPO_VERSION_TO_SPECS[instance["repo"]][instance["version"]]
```

Each spec holds `python`, `pip_packages`, `packages`, `install`, `pre_install`
and `test_cmd`.

IMPORTANT: this table is absent from `swebench==5.0.2`, which is what
`swebench_score.py` pins. It is present in `swebench==4.0.5`. Pin `4.0.5` in
the PEP 723 block of the run script, or copy the table into the `bench`
directory.

## The work

For each instance, after the clone and before the agent:

1. Read the spec of the repo and the version.
2. Make a virtual environment in the clone:
   `uv venv --python <spec python> .venv`.
3. Install `pip_packages`, then `packages` when it names a requirements file.
4. Run the `install` command of the spec, with the Python of that environment.
5. Put `<repo>/.venv/bin` first on the `PATH` of the agent.
6. Record the time of this step, and its exit code.
7. Stop the instance and record the condition when the environment does not
   build. Do not start the agent. A failed environment is not a failure of the
   agent, and it must not be part of the score.

## The limits of this machine

This agent uses local models, so it runs on the mac, and not in a linux
container. Two groups of instances cannot run as they are:

| Condition | Instances of the Lite split |
|---|---|
| The spec wants Python 3.6, and uv has no 3.6 or 3.7 build for arm64 | 77 |
| The spec has `pre_install` with `apt-get`, which is linux only | 44 |

The two groups do not intersect, thus **179 of the 300 instances can run on
this machine**. For the 3.6 group, you can try Python 3.8 and record the
change, or leave them out. Make that a command-line choice.

## When it is complete

- An instance starts with an environment that imports the package it tests.
- The count of environment calls in the transcripts falls to almost zero.
- A short run of three django instances makes patches with no pip work in
  them.
- An instance with an environment that does not build is recorded, and is not
  part of the score.

Related: [[bench-give-the-agent-a-clean-environment-not-the-harness-one]] #bench
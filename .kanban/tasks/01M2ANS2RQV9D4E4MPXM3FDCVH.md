---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2axkg4hh3ksrx5xgcha9yka
  text: |-
    ### research

    What I proved on this machine, before I wrote code:

    - `swebench==4.0.5` holds `MAP_REPO_VERSION_TO_SPECS` at `swebench.harness.constants`. `swebench==4.0.5` + `datasets==5.0.1` + `rich==15.0.0` resolve together, so the run script can pin all three.
    - `uv` has no CPython 3.6 and no 3.7 build for macOS arm64. It has 18 builds of 3.8, and a 3.9 build is installed here.
    - Of the 300 instances of the Lite split: 77 want Python 3.6, 44 have a `pre_install`, and the two groups do not intersect. 179 can run here. Of the 44, only 23 use `apt-get`; the others use `sed -i 's/x/y/' file`, which the BSD `sed` of macOS does not accept either. So the whole `pre_install` group is out, and the number of the card, 44, is right.

    One fact the card does not hold, and it changes the work:

    - `packages: "requirements.txt"` does NOT mean a file with that name at the root of the repository. The harness reads `MAP_REPO_TO_REQS_PATHS[repo]` for the path, for example `tests/requirements/py3.txt` for django, and it then gets that file from the network. 125 instances of the Lite split use this, and all five of their repositories have an entry in that table. The clone already holds the file, so this work reads it from the clone and asks for no network.
    - `packages: "environment.yml"` (27 instances: matplotlib and xarray) is a conda file, and pip cannot read it. Those instances get `pip_packages` and the `install` command only, exactly as the card says.

    The `install` command of a spec is a shell line, for example `python -m pip install -e .[test] --verbose`. This work runs each one as `/bin/sh -c <line>`, so no command needs `shell=True`.
  timestamp: 2026-09-12T13:41:10.929102+00:00
- actor: claude-code
  id: 01m2ayejf42q7yytcp3c9w4fyj
  text: |-
    ### what landed

    `bench/swebench_venv.py` is the new module, with `bench/test_swebench_venv.py`
    beside it (43 tests, no network, no real build: each test gives the module a
    stand-in for `subprocess.run`, as `test_swebench_docker.py` does).

    The driver now does five steps for each instance: clone, checkout, clean,
    BUILD THE ENVIRONMENT, then the agent. The build:

    1. reads `MAP_REPO_VERSION_TO_SPECS[repo][version]`;
    2. `uv venv --seed --python <the version of the spec> .venv` in the clone.
       `--seed` is necessary: the `install` command of each spec is
       `python -m pip install ...`, and a virtual environment of `uv` holds no pip
       without it;
    3. installs `pip_packages` with the ABSOLUTE Python of that environment, so a
       command cannot install into the Python of this machine;
    4. installs the requirements file, which it finds in the clone with
       `MAP_REPO_TO_REQS_PATHS`;
    5. runs the `install` line of the spec as `/bin/sh -c <line>`, so no command
       needs `shell=True`;
    6. gives each command the environment of the agent, with `<clone>/.venv/bin`
       FIRST on the PATH and `VIRTUAL_ENV` set.

    The build stops at the first command that fails, because each command needs
    the one before it. A command that is absent gives exit code 127, and one that
    goes past the limit of 1800 seconds gives 124.

    The record of an instance grows from nine names to fourteen: `env_status`,
    `env_python`, `env_seconds`, `env_exit_code` and `env_reason`. An instance
    that does not build gets a record row and NO prediction row, so it is not part
    of the score, and a later run does it again.

    Other changes:
    - `swebench_run.py` pins `swebench==4.0.5` in its PEP 723 block, and it has
      the new option `--oldest-python`.
    - `stream_agent` takes the environment as an argument, in place of making it.
    - `AGENT_EXCLUDES` holds `.venv` too, as a second guard for a run that commits
      the environment.
    - `swebench_env.py` gives the name `VIRTUAL_ENV_VARIABLE` to the literal it
      used twice, and `swebench_venv.py` reads that name.
    - The README has a new section, the record table, and the new option.

    ### the proof on this machine

    Two real builds, by hand, with the module (the unit tests build nothing):

    ```
    psf__requests-2317   -> built, python 3.9, 2.4s, `import requests` ok
    django__django-14787 -> built, python 3.9, 12.4s, `import django` ok
    ```

    And the test runner of django then runs in that clone with no more work:

    ```
    ./tests/runtests.py --settings=test_sqlite utils_tests.test_html
    Testing against Django installed in '<clone>/django'
    Ran 16 tests in 0.058s
    ```

    One acceptance line of the card needs a whole agent run, and not this step:
    "a short run of three django instances makes patches with no pip work in
    them". That measure belongs to
    [[bench-measure-the-instance-limit-again-after-the-environment-work]], which
    this card blocks.

    ### what I found, and did not do

    105 instances have a `packages` value that is a word list of conda names
    (sympy 76, scikit-learn 23, requests 6, astropy 2), and none of them gets
    pytest from `pip_packages`. The card says to install `packages` "when it names
    a requirements file", so this work does not install a word list, and those
    instances build but have no test runner. Measured: `psf__requests-2317` builds
    and imports, and `python -m pytest --version` then answers "No module named
    pytest". That is a new task, ^j258qe2.
  timestamp: 2026-09-12T13:55:58.052165+00:00
- actor: claude-code
  id: 01m2ayeq2zckv5q4vke3b627bm
  text: |-
    ### implement — changed
    - evidence: 8 files — bench/swebench_venv.py (new), bench/test_swebench_venv.py (new, 43 tests), bench/swebench_record.py (five `env_` names), bench/test_swebench_record.py, bench/swebench_run.py (the build step, `--oldest-python`, the swebench 4.0.5 pin), bench/swebench_env.py (`VIRTUAL_ENV_VARIABLE`), bench/README.md, .github/workflows/bench.yml. `python3 -m unittest discover --start-directory bench --pattern 'test_*.py'` -> 124 tests, OK.
    - next: /review
  timestamp: 2026-09-12T13:56:02.783869+00:00
depends_on:
- 01M2ANQH644SDC0AJ9HK6T40PJ
position_column: doing
position_ordinal: '80'
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
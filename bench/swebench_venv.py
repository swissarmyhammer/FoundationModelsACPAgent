"""
swebench_venv.py -- the Python environment of one SWE-bench instance.

`swebench_run.py` clones the repository of an instance, and it sets that clone
to the commit before the fix. A SWE-bench repository does not import from a
source checkout, so an agent that gets only the clone must build the
environment itself before it can run one test.

The run of 2026-09-11 shows what that costs. Of 707 tool calls of the agent,
219 were about pip, uv, virtual environments, `PYTHONPATH` or absent modules.
For `astropy__astropy-6938` it was 37 of 80 calls, and the last one was call
78 of 80. The agent never got a working environment. Its transcripts hold:

    ModuleNotFoundError: No module named 'erfa'
    ImportError: You appear to be trying to import astropy from within a
    source checkout

So the driver builds the environment, and the agent gets the task. The
official package publishes the environment of each instance in
`MAP_REPO_VERSION_TO_SPECS`, with the Python version, the packages and the
install command of the repository at that version. This module reads that
table, it makes a virtual environment in the clone with `uv`, it installs the
packages of the spec, and it puts that environment first on the PATH of the
agent.

WHAT THIS MACHINE CANNOT BUILD

The agent uses local models, so it runs on the mac and not in a linux
container. Two groups of the Lite split do not build here:

| Condition | Instances |
|---|---|
| The spec wants Python 3.6, and `uv` has no 3.6 and no 3.7 build for arm64 | 77 |
| The spec has a `pre_install`, which is written for linux | 44 |

The two groups do not intersect, so 179 of the 300 instances build here. For
the first group a person can name an older Python to try, and the record of
the instance then says which Python it got. A `pre_install` holds `apt-get`,
or a `sed -i 's/x/y/' file` in the form of GNU that the `sed` of macOS does
not accept, so no choice answers that group.

An instance that does not build is recorded, and the agent does not start.
A failed environment is not a failure of the agent, and it must not be part of
the score.

EACH PATH OF THE PUBLISHED TABLE STANDS IN THE CLONE

`MAP_REPO_TO_REQS_PATHS` says where the requirements file of a repository
stands, and this module joins that path to the clone. A path with a `..` part,
or an absolute path, would thus name a file OUTSIDE the clone. So
`checked_clone_path` is the one gate, and each function that makes a path from
that table calls it. A path that leaves the clone raises a `ClonePathError`,
and the driver then records that instance as an error of its own.

Each function takes the runner as an argument, and the default is
`subprocess.run`. A test thus gives a stand-in, and it needs no `uv` and no
network.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block
of a module that the script imports. It needs the standard library and
`swebench_env.py`, and the table comes from the `swebench` package that
`swebench_run.py` pins.
"""
import os
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from swebench_env import VIRTUAL_ENV_VARIABLE, agent_environment

# What the driver did with the environment of an instance.
BUILT = "built"
FAILED = "failed"
UNSUPPORTED = "unsupported"
# Where the environment of an instance stands, below the clone. It is not a
# tracked file of the repository, so `git diff <base_commit>` leaves it out of
# the patch.
VENV_DIRECTORY = ".venv"
# Where a virtual environment keeps its programs, and the name of its Python.
VENV_BIN = "bin"
VENV_PYTHON = "python"
# The command that makes the environment. `--seed` is what puts `pip` in it,
# and the install command of each spec is `python -m pip install ...`.
VENV_COMMAND = ("uv", "venv", "--seed", "--python")
# What follows the Python of the environment, to install a package with it.
PIP_MODULE = ("-m", "pip", "install")
# The option that names a requirements file.
REQUIREMENTS_OPTION = "-r"
# The shell that runs the install command of a spec. That command is a line
# and not a list, so it needs a shell -- but the runner then needs no
# `shell=True`, because the shell is the program of the command.
SHELL_COMMAND = ("/bin/sh", "-c")
# The Python versions that `uv` does not build for macOS arm64. Measured with
# `uv python list --all-versions` on uv 0.12.5: 18 builds of 3.8, and none of
# 3.7 and none of 3.6.
PYTHON_WITH_NO_BUILD = ("3.6", "3.7")
# The value of `packages` that names a requirements file. The file itself is
# NOT at the root of the repository: the official harness reads
# `MAP_REPO_TO_REQS_PATHS` for the path, and django keeps its file at
# `tests/requirements/py3.txt`.
REQUIREMENTS_PACKAGES = "requirements.txt"
# Where to look when that table names no path for a repository.
DEFAULT_REQUIREMENTS_PATHS = ("requirements.txt",)
# How long one build command may take, in seconds. A pip that waits for a
# server would otherwise hold the whole run open, and a run has no watchdog
# over this step. A build of astropy compiles its extensions, so the limit is
# of minutes and not of seconds.
BUILD_SECONDS = 1800
# The exit code of a command that did its work.
COMMAND_DID_ITS_WORK = 0
# The exit code the record keeps for a command that went past the limit of
# time. `timeout(1)` gives this code for the same condition.
TIMED_OUT_EXIT_CODE = 124
# The exit code the record keeps for a command that is not on the PATH. A
# shell gives this code for the same condition.
COMMAND_IS_ABSENT_EXIT_CODE = 127
# How many lines of a command that failed the report keeps. A pip that fails
# writes hundreds of lines, and the last ones hold the cause.
OUTPUT_LINES = 40
# What a person reads when a path of the published table leaves the clone.
CLONE_PATH_REFUSED = (
    "the path {path!r} of the published table does not stand in the clone "
    "{clone}. A path of that table names a file OF the repository, so it is "
    "relative to the clone and it holds no `..` part."
)


class ClonePathError(ValueError):
    """A path that does not stand in the clone of an instance.

    This error has a name of its own, so that a caller can catch this
    condition alone and say what a person must do. It is a `ValueError`,
    because a path that leaves the clone is a bad VALUE of an argument, and a
    caller that knows only the errors of the standard library still works.
    """


def checked_clone_path(clone, path):
    """The path in the clone, when it stands in the clone.

    - clone: the directory of the cloned repository.
    - path: a path of the published table, for example
      `tests/requirements/py3.txt`.

    This is the one gate of the module. `MAP_REPO_TO_REQS_PATHS` comes from
    the `swebench` package, and each path of it becomes a path of this
    machine. A path with a `..` part, or an absolute path, thus names a file
    OUTSIDE the clone, and the clone is the one directory of an instance.

    The gate resolves the two paths and it compares them, so a symbolic link
    that leaves the clone is refused too. It gives the RESOLVED path, because
    a command must get the path that the gate read, and not another one.

    Each function of this module that makes a path from a value of that table
    calls this one, because a gate that one door of two holds is not a gate.
    """
    root = Path(clone).resolve()
    inside = (root / path).resolve()
    if inside.is_relative_to(root):
        return inside
    raise ClonePathError(CLONE_PATH_REFUSED.format(path=path, clone=root))


@dataclass(frozen=True)
class EnvironmentReport:
    """What the driver did with the environment of one instance.

    - status: `BUILT`, `FAILED` or `UNSUPPORTED`.
    - python: the Python version of the environment, or None when none was
      chosen.
    - seconds: the time of the build, or None when no build ran.
    - exit_code: the exit code of the command that failed, or None.
    - reason: why the instance did not run, or None when it did.
    - output: what the command that failed wrote.
    """

    status: str
    python: str | None
    seconds: float | None
    exit_code: int | None
    reason: str | None
    output: str


def published_specs():
    """The table of instance environments that the `swebench` package holds.

    The import stands here, and not at the top of the module, so that a test
    of this module needs the standard library only. The CI job installs
    nothing, and it runs every `bench/test_*.py`.
    """
    from swebench.harness.constants import MAP_REPO_VERSION_TO_SPECS

    return MAP_REPO_VERSION_TO_SPECS


def published_requirements_paths():
    """The table of requirements paths that the `swebench` package holds.

    `packages: "requirements.txt"` names no file of the root, so this table is
    what says where the file of a repository stands. The import stands here
    for the reason `published_specs` gives.
    """
    from swebench.harness.constants import MAP_REPO_TO_REQS_PATHS

    return MAP_REPO_TO_REQS_PATHS


def instance_spec(repo, version, specs=None):
    """The environment spec of one instance.

    - repo: the name of the repository, for example `django/django`.
    - version: the version of the instance.
    - specs: the table to read, or None for the published one.

    The spec holds `python`, `pip_packages`, `packages`, `install`,
    `pre_install` and `test_cmd`. Each name is optional, except `python`.
    """
    table = published_specs() if specs is None else specs
    return table[repo][version]


def instance_python(spec, oldest_python=None):
    """The Python version that the environment of one instance gets.

    - spec: the spec of the instance.
    - oldest_python: the version to try when `uv` has no build of the one the
      spec names, or None to leave that instance out.

    Returns the version, or None when this machine can build none.
    """
    python = spec["python"]
    if python not in PYTHON_WITH_NO_BUILD:
        return python
    return oldest_python


def unsupported_reason(spec, oldest_python=None):
    """Why this machine cannot build the environment of one instance.

    - spec: the spec of the instance.
    - oldest_python: what the person chose for the old Python group.

    Returns the reason, or None when the environment can build here.
    """
    if spec.get("pre_install"):
        return (
            "the spec has a `pre_install`, and those commands are written for "
            "linux: `apt-get`, or a `sed -i` in the form of GNU"
        )
    if instance_python(spec, oldest_python) is None:
        return (
            f"the spec wants Python {spec['python']}, and `uv` has no build of "
            f"it for this machine. Name another one with --oldest-python"
        )
    return None


def venv_path(clone):
    """The virtual environment of one instance.

    - clone: the directory of the cloned repository.
    """
    return Path(clone) / VENV_DIRECTORY


def venv_bin(clone):
    """The directory of programs of the environment of one instance.

    - clone: the directory of the cloned repository.
    """
    return venv_path(clone) / VENV_BIN


def venv_python(clone):
    """The Python of the environment of one instance.

    - clone: the directory of the cloned repository.

    An install command that names this path cannot install into the Python of
    this machine, whatever the PATH holds.
    """
    return venv_bin(clone) / VENV_PYTHON


def instance_path(clone, path):
    """The PATH of the agent, with the environment of the instance first.

    - clone: the directory of the cloned repository.
    - path: the PATH the agent gets without this environment.

    First is the point. The agent asks for `python` and for `pytest`, and it
    must get the ones of the instance.
    """
    return os.pathsep.join([str(venv_bin(clone)), path])


def instance_environment(clone, parent=None):
    """The environment of the process of the agent, for one instance.

    - clone: the directory of the cloned repository.
    - parent: the environment of the harness. The default is this process.

    `swebench_env.py` decides what the agent keeps and what it loses, and this
    adds the environment of the instance to that answer: first on the PATH,
    and named by `VIRTUAL_ENV` as an activated environment names it.
    """
    environment = agent_environment(parent)
    environment["PATH"] = instance_path(clone, environment["PATH"])
    environment[VIRTUAL_ENV_VARIABLE] = str(venv_path(clone))
    return environment


def requirements_file(clone, repo, paths=None):
    """The requirements file of one repository, in the clone.

    - clone: the directory of the cloned repository.
    - repo: the name of the repository, for example `django/django`.
    - paths: the table of paths to read, or None for the published one.

    Returns the first path of the table that the clone holds, or None. The
    official harness gets this file from the network. The clone already holds
    it at the commit of the instance, so this reads the disk.

    Each path of the table goes through `checked_clone_path`, because the
    table is published data and a path of it must not leave the clone.
    """
    table = published_requirements_paths() if paths is None else paths
    for path in table.get(repo, DEFAULT_REQUIREMENTS_PATHS):
        found = checked_clone_path(clone, path)
        if found.is_file():
            return found
    return None


def pip_command(clone, arguments):
    """One install command, with the Python of the environment of an instance.

    - clone: the directory of the cloned repository.
    - arguments: what to install.
    """
    return [str(venv_python(clone)), *PIP_MODULE, *arguments]


def build_commands(clone, spec, python, requirements):
    """Every command that builds the environment of one instance, in order.

    - clone: the directory of the cloned repository.
    - spec: the spec of the instance.
    - python: the Python version of the environment.
    - requirements: the requirements file of the clone, or None.

    The first command makes the environment, and each command after it needs
    that environment. The install command of the spec goes last, because it
    installs the package of the instance itself.
    """
    commands = [[*VENV_COMMAND, python, VENV_DIRECTORY]]
    packages = spec.get("pip_packages")
    if packages:
        commands.append(pip_command(clone, packages))
    if requirements is not None:
        commands.append(pip_command(clone, [REQUIREMENTS_OPTION, str(requirements)]))
    install = spec.get("install")
    if install:
        commands.append([*SHELL_COMMAND, install])
    return commands


def last_lines(text):
    """The end of what a command wrote.

    - text: everything the command wrote.

    A pip that fails writes hundreds of lines, and the cause is at the end.
    """
    return "\n".join(text.splitlines()[-OUTPUT_LINES:])


def run_command(command, clone, environment, run):
    """Run one build command, and say how it ended.

    - command: the command to run, as a list.
    - clone: the directory the command runs in.
    - environment: the environment the command gets.
    - run: the runner, with the shape of `subprocess.run`.

    Returns a pair of the exit code and what the command wrote. A machine
    without `uv` raises an OSError here, and a command that goes past the
    limit raises a TimeoutExpired. Each of them ends the build, and neither
    of them ends the run.
    """
    try:
        finished = run(
            command,
            cwd=str(clone),
            env=environment,
            capture_output=True,
            text=True,
            timeout=BUILD_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return TIMED_OUT_EXIT_CODE, f"it took more than {BUILD_SECONDS} seconds"
    except OSError as error:
        return COMMAND_IS_ABSENT_EXIT_CODE, str(error)
    written = (finished.stdout or "") + (finished.stderr or "")
    return finished.returncode, last_lines(written)


def failed_reason(command, exit_code):
    """Why the environment of an instance did not build, in one line.

    - command: the command that failed.
    - exit_code: the code it gave.

    A reason without the command tells a reader nothing, so this names it.
    """
    return f"`{' '.join(command)}` gave exit code {exit_code}"


def missing_requirements_reason(repo, paths):
    """Why a spec that names a requirements file gets no file.

    - repo: the name of the repository.
    - paths: the table of paths that was read.

    An environment with no pytest cannot run one test of the instance, so this
    ends the build. The message names each path, because that is the fact a
    person needs to correct it.
    """
    wanted = ", ".join(paths.get(repo, DEFAULT_REQUIREMENTS_PATHS))
    return (
        f"the spec names a requirements file, and the clone holds none of: "
        f"{wanted}"
    )


def prepare_environment(
    clone,
    repo,
    version,
    *,
    oldest_python=None,
    specs=None,
    requirements_paths=None,
    run=subprocess.run,
):
    """Build the Python environment of one instance, in its clone.

    - clone: the directory of the cloned repository.
    - repo: the name of the repository, for example `django/django`.
    - version: the version of the instance.
    - oldest_python: the version to try for the old Python group, or None.
    - specs: the table of specs, or None for the published one.
    - requirements_paths: the table of paths, or None for the published one.
    - run: the runner, with the shape of `subprocess.run`.

    Returns an `EnvironmentReport`. The build stops at the first command that
    fails, because each command needs the one before it. An instance that this
    machine cannot build runs no command at all.
    """
    spec = instance_spec(repo, version, specs)
    reason = unsupported_reason(spec, oldest_python)
    if reason is not None:
        return EnvironmentReport(UNSUPPORTED, None, None, None, reason, "")
    python = instance_python(spec, oldest_python)
    paths = requirements_paths
    if paths is None:
        paths = published_requirements_paths()
    started = time.monotonic()
    requirements = None
    if spec.get("packages") == REQUIREMENTS_PACKAGES:
        requirements = requirements_file(clone, repo, paths)
        if requirements is None:
            return EnvironmentReport(
                FAILED,
                python,
                time.monotonic() - started,
                None,
                missing_requirements_reason(repo, paths),
                "",
            )
    environment = instance_environment(clone)
    for command in build_commands(clone, spec, python, requirements):
        exit_code, output = run_command(command, clone, environment, run)
        if exit_code != COMMAND_DID_ITS_WORK:
            return EnvironmentReport(
                FAILED,
                python,
                time.monotonic() - started,
                exit_code,
                failed_reason(command, exit_code),
                output,
            )
    return EnvironmentReport(
        BUILT, python, time.monotonic() - started, None, None, ""
    )

"""
swebench_env.py -- build the Python environment of one SWE-bench instance.

`swebench_run.py` clones the repository at the commit before the fix, and it
then calls `prepare` from this module. `prepare` makes a virtual environment,
installs the packages of the instance, and installs the repository itself.
The agent thus finds a working `python` on its PATH, and it can reproduce the
problem in its first minute.

WHY THIS EXISTS

Without it the agent finds a source tree that it cannot import, because the
compiled extensions are absent. A run of astropy__astropy-12907 showed the
cost: the model spent 56 minutes of its 60 minute limit on build errors,
import errors and package versions, and it made no patch.

THE RECIPES

The recipes are the ones the official harness uses, from
`MAP_REPO_VERSION_TO_SPECS`. Each recipe gives the Python version, the pinned
packages, an optional step before the install, and the install command. This
module needs `swebench==4.1.0` for them, because 5.x no longer carries the
recipes. The score script pins the same version, and 5.x also drops the
arguments that build the images on this machine.

WHAT IS NOT THE SAME AS DOCKER

The score step runs the tests in the official container. This environment is
for the agent only, on this machine, so that the model can read a traceback
that is true. A patch that works here can still fail in the container.

TWO CONDITIONS NEED CARE, AND THIS MODULE CONTROLS BOTH

  * The tree must be clean when the agent starts. A step before the install
    can change a TRACKED file: the astropy recipe rewrites `pyproject.toml`.
    That change would go into the patch of the agent, and the patch must hold
    the work of the model and nothing more. So `prepare` restores every
    tracked file after the install, and it reports a tree that stays dirty.

  * A recipe is written for GNU tools. `sed -i EXPR` writes the file in place
    on GNU, and the BSD `sed` of macOS reads `EXPR` as the backup suffix. So
    `prepare` puts a small `sed` shim first on the PATH of the recipe steps.
"""
import os
import shlex
import shutil
import subprocess
import time
from pathlib import Path

from swebench.harness.constants import MAP_REPO_VERSION_TO_SPECS
from swebench.harness.test_spec.python import get_environment_yml, get_requirements

from swebench_common import log

# --- config -----------------------------------------------------------------
# The wall-clock limit of one environment build. It is the limit of the whole
# build, and not of one step. A first build of a repository gets its packages
# over the network, and a repository with C extensions is compiled.
DEFAULT_ENV_TIMEOUT_S = 1800
# The Python of the recipe can be too old for this machine. uv builds no
# 3.5 and no 3.6 for Apple Silicon. The build then uses this version, and it
# says so. The version of the recipe is tried first, always.
FALLBACK_PYTHON = "3.9"
# How many lines of a failed step go into the message.
TAIL_LINES = 20
# The name of the environment in a conda `environment.yml`. The recipes of
# the harness use this name.
ENV_YML_NAME = "testbed"
# The compiler flags of the build of the repository, and of that build only.
# The clang of a recent macOS makes three old C patterns errors. The C of a
# repository of this age has them, thus astropy 5.1 does not compile without
# this:
#     wcslib_wtbarr_wrap.c:208: error: incompatible function pointer types
# These flags make the three warnings again. The agent does not get them,
# because the agent does not build.
BUILD_CFLAGS = (
    "-Wno-error=incompatible-function-pointer-types "
    "-Wno-error=implicit-function-declaration "
    "-Wno-error=int-conversion"
)
# ----------------------------------------------------------------------------


class SetupFailed(Exception):
    """The environment of the instance was not built.

    The runner writes no prediction row for an instance that raises this, so
    a later run does the instance again.
    """


def tail(text):
    """The last lines of the output of a step, for a message."""
    lines = [ln for ln in (text or "").splitlines() if ln.strip()]
    return "\n".join(f"    {ln}" for ln in lines[-TAIL_LINES:])


class Deadline:
    """The time that is left of the limit of the whole build."""

    def __init__(self, seconds):
        self.end = time.monotonic() + seconds

    def left(self, step):
        """The seconds that are left, or SetupFailed when there are none."""
        left = self.end - time.monotonic()
        if left <= 0:
            raise SetupFailed(f"no time is left for {step}")
        return left


def spec_of(inst):
    """The recipe of one instance, by repository and version."""
    repo = inst["repo"]
    version = inst.get("version")
    try:
        return MAP_REPO_VERSION_TO_SPECS[repo][version]
    except KeyError:
        raise SetupFailed(f"there is no recipe for {repo} {version}")


def run_step(name, argv, cwd, env, deadline, fatal=True):
    """Run one step of the build, and report it.

    - name: what the step does, for the message.
    - argv: the program and its arguments.
    - fatal: True raises SetupFailed when the step fails. False writes a
      warning and lets the build go on, because the install of the
      repository can still get what the step did not.

    Returns the finished process.
    """
    try:
        done = subprocess.run(
            argv, cwd=cwd, env=env, capture_output=True, text=True,
            timeout=deadline.left(name),
        )
    except subprocess.TimeoutExpired:
        raise SetupFailed(f"{name} was too slow")
    except OSError as exc:
        raise SetupFailed(f"{name} did not start: {exc}")
    if done.returncode != 0:
        detail = tail(f"{done.stdout}\n{done.stderr}")
        if fatal:
            raise SetupFailed(f"{name} failed:\n{detail}")
        log(f"    [yellow]{name} failed, and the build goes on[/]:\n{detail}")
    return done


def make_sed_shim(work):
    """Write a `sed` that accepts the GNU spelling, and give its directory.

    GNU `sed -i EXPR` writes the file in place and keeps no backup. The BSD
    `sed` of macOS reads the next word as the backup suffix, so it reads
    `EXPR` as that suffix and then it finds no script. The shim puts an empty
    suffix after a plain `-i`, and it passes every other argument through.
    """
    shim = work / "shim"
    shim.mkdir(exist_ok=True)
    path = shim / "sed"
    path.write_text(
        "#!/bin/sh\n"
        "# Make the BSD sed of macOS accept the GNU spelling `sed -i EXPR`.\n"
        "n=$#\n"
        "i=0\n"
        "while [ $i -lt $n ]; do\n"
        "    arg=$1\n"
        "    shift\n"
        '    if [ "$arg" = "-i" ]; then\n'
        '        set -- "$@" -i ""\n'
        "    else\n"
        '        set -- "$@" "$arg"\n'
        "    fi\n"
        "    i=$((i + 1))\n"
        "done\n"
        'exec /usr/bin/sed "$@"\n'
    )
    path.chmod(0o755)
    return shim


def environment_of(venv, shim=None):
    """The environment variables that make `venv` the Python of a command."""
    env = dict(os.environ)
    env["VIRTUAL_ENV"] = str(venv)
    parts = [str(venv / "bin")]
    if shim is not None:
        parts.insert(0, str(shim))
    env["PATH"] = os.pathsep.join(parts + [env.get("PATH", "")])
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    return env


def agent_environment(venv):
    """The environment the agent gets, so its shell finds this `python`."""
    return environment_of(venv)


def make_venv(work, spec, deadline):
    """Make the virtual environment, and give its path.

    The Python version of the recipe is tried first. uv builds no Python 3.5
    and no Python 3.6 for Apple Silicon, so a version that uv cannot get
    falls back to FALLBACK_PYTHON, and the fall back is reported.
    """
    if shutil.which("uv") is None:
        raise SetupFailed("uv is not on the PATH")
    venv = work / "venv"
    wanted = str(spec.get("python") or FALLBACK_PYTHON)
    last = None
    for version in dict.fromkeys([wanted, FALLBACK_PYTHON]):
        try:
            done = subprocess.run(
                ["uv", "venv", "--python", version, "--seed", str(venv)],
                capture_output=True, text=True, timeout=deadline.left("uv venv"),
            )
        except subprocess.TimeoutExpired:
            raise SetupFailed("uv venv was too slow")
        if done.returncode == 0:
            if version != wanted:
                log(
                    f"    [yellow]python {wanted} is not available here, and "
                    f"the build uses python {version}[/]"
                )
            return venv
        last = done
    raise SetupFailed(f"uv venv failed:\n{tail(last.stdout + last.stderr)}")


def pip_names_of_environment_yml(inst):
    """The package names of a conda `environment.yml`, as pip names.

    A conda file is not a pip file. This reads the names and the versions
    only, and it leaves out `python` and the channels. The result is what pip
    can try. A name that is a conda name alone fails, and the install of that
    group is not fatal.
    """
    try:
        text = get_environment_yml(inst, ENV_YML_NAME)
    except Exception as exc:  # the file is read over the network
        log(f"    [yellow]the environment.yml was not read[/]: {exc}")
        return []
    names = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("- "):
            continue
        item = line[2:].strip()
        if not item or item.endswith(":") or "/" in item:
            continue
        name = item.split("=")[0].strip()
        if name in {"python", "pip", "conda"}:
            continue
        if "=" in item:
            version = item.split("=")[1].strip()
            names.append(f"{name}=={version}" if version else name)
        else:
            names.append(item)
    return names


def dependency_groups(work, inst, spec):
    """The groups of `uv pip install` arguments of one recipe.

    A group is a list, and each group is installed alone. A group that fails
    does not stop the build, because the install of the repository can still
    get what the group did not.
    """
    groups = []
    packages = spec.get("packages")
    if packages == "requirements.txt":
        try:
            text = get_requirements(inst)
        except Exception as exc:  # the file is read over the network
            log(f"    [yellow]the requirements.txt was not read[/]: {exc}")
        else:
            path = work / "requirements.txt"
            path.write_text(text)
            groups.append(["-r", str(path)])
    elif packages == "environment.yml":
        names = pip_names_of_environment_yml(inst)
        if names:
            groups.append(names)
    elif packages:
        groups.append(shlex.split(str(packages)))
    pip_packages = spec.get("pip_packages")
    if pip_packages:
        groups.append(list(pip_packages))
    return [g for g in groups if g]


def restore_tracked(repo):
    """Put every tracked file of the repository back, and say what changed.

    A step of the recipe can change a tracked file, and that change is not
    the work of the agent. The install is complete when this runs, so the
    change has done its work already and the file can go back.

    Returns the names of the files that were restored.
    """
    names = subprocess.run(
        ["git", "-C", str(repo), "diff", "--name-only"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if names:
        subprocess.run(
            ["git", "-C", str(repo), "checkout", "--", "."],
            capture_output=True, text=True, check=True,
        )
    return names


def prepare(work, repo, inst, timeout=DEFAULT_ENV_TIMEOUT_S):
    """Build the environment of one instance, and give the virtual environment.

    - work: the temporary directory of the instance. The virtual environment
      goes beside the repository, and not in it, so that no file of it can
      reach the patch.
    - repo: the clean checkout of the commit before the fix.
    - inst: the row of the instance, from the dataset.
    - timeout: the wall-clock limit of the whole build, in seconds.

    Raises SetupFailed when the environment cannot be built.
    """
    work = Path(work)
    repo = Path(repo)
    deadline = Deadline(timeout)
    spec = spec_of(inst)

    venv = make_venv(work, spec, deadline)
    shim = make_sed_shim(work)
    env = environment_of(venv, shim)
    env["CFLAGS"] = f"{env.get('CFLAGS', '')} {BUILD_CFLAGS}".strip()
    python = venv / "bin" / "python"

    for group in dependency_groups(work, inst, spec):
        run_step(
            "the package install",
            ["uv", "pip", "install", "--python", str(python), *group],
            cwd=str(repo), env=env, deadline=deadline, fatal=False,
        )

    for command in spec.get("pre_install") or []:
        run_step(
            "the step before the install",
            ["/bin/sh", "-c", command],
            cwd=str(repo), env=env, deadline=deadline,
        )

    install = spec.get("install")
    if install:
        run_step(
            "the install of the repository",
            ["/bin/sh", "-c", install],
            cwd=str(repo), env=env, deadline=deadline,
        )

    restored = restore_tracked(repo)
    if restored:
        log(f"    the build changed {len(restored)} tracked file(s), and they are back")
    left = subprocess.run(
        ["git", "-C", str(repo), "diff", "--name-only"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if left:
        raise SetupFailed(
            "the tree is dirty after the build, and the patch of the agent "
            f"would hold this too: {' '.join(left)}"
        )
    return venv

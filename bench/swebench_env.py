"""
swebench_env.py -- the environment that the process of the agent gets.

`swebench_run.py` starts with `#!/usr/bin/env -S uv run --script`, so the
harness stands in an ephemeral environment that `uv` makes. `VIRTUAL_ENV` and
the first entries of `PATH` then point at that environment. A child process
that gets the same environment finds the Python of the HARNESS, and not the
Python of the instance.

The run of 2026-09-11 shows what that costs. The agent found the Python of
the harness, and it tried to use it:

    .../.cache/uv/environments-v2/swebench-run-296e9fecef83dd53/bin/python:
    No module named pip

The agent then examined that directory, it tried to install packages in it,
and one time it looked for a module across the full disk. None of that work
is the task of the instance.

So this module makes a clean environment, and `swebench_run.py` gives that
environment to the agent with `env=`. The agent keeps `HOME`, `USER`,
`TMPDIR`, `LANG` and the directories of the system, because it needs them. It
loses the variables of the harness and the PATH entries of the harness.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block
of a module that the script imports. This module needs the standard library
only.
"""
import os
import shutil
from pathlib import Path

# The variables that send a child process to the Python of the harness.
HARNESS_VARIABLES = ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME")
# `uv` made the environment of the harness, and it reads every variable with
# this prefix. `UV_CACHE_DIR` is one of them.
HARNESS_PREFIXES = ("UV_",)
# The directories that the agent gets when the harness holds every entry of
# its own PATH. Without them the agent finds no program at all.
SYSTEM_PATH_ENTRIES = ("/usr/bin", "/bin", "/usr/sbin", "/sbin")
# Where `uv` keeps the environments it makes, when `UV_CACHE_DIR` does not
# say. `uv` follows the XDG base directory specification here.
DEFAULT_CACHE_LEAF = ".cache"
UV_CACHE_LEAF = "uv"
# The program that the log line of a run reports. It answers the question
# "which Python does the agent get".
PYTHON_COMMAND = "python3"


def uv_cache(parent):
    """The directory where `uv` keeps the environments it makes.

    - parent: the environment of the harness.

    Returns the directory, or None when the environment says too little to
    name it. `UV_CACHE_DIR` names it directly. Without that variable the
    directory stands below `XDG_CACHE_HOME`, and then below the home.
    """
    named = parent.get("UV_CACHE_DIR")
    if named:
        return named
    cache_home = parent.get("XDG_CACHE_HOME")
    if not cache_home:
        home = parent.get("HOME")
        if not home:
            return None
        cache_home = os.path.join(home, DEFAULT_CACHE_LEAF)
    return os.path.join(cache_home, UV_CACHE_LEAF)


def harness_roots(parent):
    """The directories that hold the environment of the harness.

    - parent: the environment of the harness.

    A PATH entry that stands below one of these directories is an entry of
    the harness, and the agent does not get it.
    """
    named = (parent.get("VIRTUAL_ENV"), uv_cache(parent))
    return [Path(directory) for directory in named if directory]


def is_harness_entry(entry, roots):
    """True when one PATH entry belongs to the environment of the harness.

    - entry: one entry of the PATH.
    - roots: the directories that `harness_roots` gives.
    """
    candidate = Path(entry)
    return any(candidate == root or root in candidate.parents for root in roots)


def is_harness_variable(name):
    """True when one variable names the environment of the harness.

    - name: the name of the variable.
    """
    return name in HARNESS_VARIABLES or name.startswith(HARNESS_PREFIXES)


def agent_path(parent):
    """The PATH of the agent: the PATH of the harness, less its own entries.

    - parent: the environment of the harness.

    An empty entry names the directory of work, and not a directory of
    programs, so the agent does not get that either. When nothing is left,
    the agent gets the directories of the system.
    """
    roots = harness_roots(parent)
    kept = [
        entry
        for entry in parent.get("PATH", "").split(os.pathsep)
        if entry and not is_harness_entry(entry, roots)
    ]
    return os.pathsep.join(kept or SYSTEM_PATH_ENTRIES)


def agent_environment(parent=None):
    """The environment of the process of the agent.

    - parent: the environment of the harness. The default is this process.

    Every variable of the harness goes, and the PATH keeps the entries of
    the harness out. Each other variable stays, because the agent needs it:
    `HOME` holds the models it reads, and `TMPDIR`, `USER` and `LANG` are
    what any program of this machine expects.
    """
    parent = os.environ if parent is None else parent
    environment = {
        name: value
        for name, value in parent.items()
        if not is_harness_variable(name)
    }
    environment["PATH"] = agent_path(parent)
    return environment


def environment_summary(environment):
    """One line that says which Python the agent gets, and on which PATH.

    - environment: the environment that `agent_environment` made.

    A run writes this line for each instance. Without it, nothing in the
    output of a run says which Python the agent found.
    """
    path = environment.get("PATH", "")
    python = shutil.which(PYTHON_COMMAND, path=path) or "none"
    return f"{PYTHON_COMMAND}: {python} . PATH: {path}"

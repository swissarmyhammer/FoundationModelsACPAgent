#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_env.py -- the proof that the agent gets a clean environment.

`swebench_run.py` starts with `uv run --script`, so the harness stands in an
ephemeral environment of its own. The agent must not get that environment: it
must not find the Python of the harness, and it must not find the cache of
`uv`.

The first group of tests starts a REAL child process with the environment
that `swebench_env.agent_environment` makes, and it reads what that process
can see. A dictionary alone does not prove what a process gets.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_env.py
    python3 bench/test_swebench_env.py
"""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from swebench_env import agent_environment, agent_path, environment_summary

# The names below are the names of a test, and not the names of this machine.
# A test that reads this machine gives a different answer on each machine.
HARNESS_HOME = "/Users/tester"
HARNESS_CACHE = f"{HARNESS_HOME}/.cache/uv"
HARNESS_VENV = f"{HARNESS_CACHE}/environments-v2/swebench-run-296e9fecef83dd53"
# The program of the child process. It writes its own environment, so a test
# reads what the process of the agent sees.
CHILD_PROGRAM = "import json, os, sys; json.dump(dict(os.environ), sys.stdout)"
# The permissions of the file that stands for a Python on the PATH.
EXECUTABLE_MODE = stat.S_IRWXU


def harness_environment(**changes):
    """An environment with the shape that `uv run --script` gives the harness.

    - changes: the entries to add, or to replace.
    """
    environment = {
        "VIRTUAL_ENV": HARNESS_VENV,
        "UV_CACHE_DIR": HARNESS_CACHE,
        "PYTHONPATH": f"{HARNESS_HOME}/harness/lib",
        "PYTHONHOME": HARNESS_VENV,
        "PATH": os.pathsep.join(
            [f"{HARNESS_VENV}/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
        ),
        "HOME": HARNESS_HOME,
        "USER": "tester",
        "TMPDIR": "/tmp/tester",
        "LANG": "en_US.UTF-8",
    }
    environment.update(changes)
    return environment


def child_environment(parent):
    """The environment that a child process of the agent sees.

    - parent: the environment of the harness.

    The child is a real process, and it writes its own environment. So the
    answer is what the operating system gave it.
    """
    result = subprocess.run(
        [sys.executable, "-c", CHILD_PROGRAM],
        env=agent_environment(parent),
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


class TheAgentProcess(unittest.TestCase):
    """What a process that the agent environment starts can see."""

    def test_it_does_not_see_the_virtual_environment_of_the_harness(self):
        """`VIRTUAL_ENV` is what sent the agent to the Python of the harness.

        In the run of 2026-09-11 the agent found that Python, and it then
        tried to install packages in the cache of `uv`.
        """
        self.assertNotIn("VIRTUAL_ENV", child_environment(harness_environment()))

    def test_it_does_not_see_the_variables_of_uv(self):
        """A `UV_*` variable points at the cache that holds that Python."""
        seen = child_environment(harness_environment(UV_PROJECT_ENVIRONMENT="x"))
        self.assertEqual([name for name in seen if name.startswith("UV_")], [])

    def test_it_does_not_see_the_python_path_and_the_python_home(self):
        """Both variables make a child read the libraries of the harness."""
        seen = child_environment(harness_environment())
        self.assertNotIn("PYTHONPATH", seen)
        self.assertNotIn("PYTHONHOME", seen)

    def test_it_sees_the_home_the_user_and_the_language(self):
        """The agent needs these. It reads its models below the home."""
        seen = child_environment(harness_environment())
        self.assertEqual(seen.get("HOME"), HARNESS_HOME)
        self.assertEqual(seen.get("USER"), "tester")
        self.assertEqual(seen.get("TMPDIR"), "/tmp/tester")
        self.assertEqual(seen.get("LANG"), "en_US.UTF-8")

    def test_its_path_holds_no_directory_of_the_harness(self):
        """A directory of the harness on the PATH gives that Python again."""
        seen = child_environment(harness_environment())
        self.assertNotIn(HARNESS_CACHE, seen.get("PATH", ""))


class TheAgentPath(unittest.TestCase):
    """Which entries of the PATH of the harness the agent gets."""

    def test_it_keeps_the_directories_of_the_system_in_order(self):
        """The agent must find `git` and the Python of the instance."""
        entries = agent_path(harness_environment()).split(os.pathsep)
        self.assertEqual(entries, ["/opt/homebrew/bin", "/usr/bin", "/bin"])

    def test_it_drops_a_directory_below_the_cache_of_uv(self):
        """`uv` writes every ephemeral environment below its cache.

        The cache of a harness that does not name `UV_CACHE_DIR` stands
        below the home, as the XDG specification says.
        """
        other = f"{HARNESS_HOME}/.cache/uv/environments-v2/other-run/bin"
        parent = harness_environment(PATH=os.pathsep.join([other, "/usr/bin"]))
        del parent["UV_CACHE_DIR"]
        self.assertEqual(agent_path(parent), "/usr/bin")

    def test_it_drops_a_directory_below_the_virtual_environment(self):
        """A virtual environment away from the cache is a harness one too."""
        venv = f"{HARNESS_HOME}/work/.venv"
        parent = harness_environment(
            VIRTUAL_ENV=venv, PATH=os.pathsep.join([f"{venv}/bin", "/usr/bin"])
        )
        self.assertEqual(agent_path(parent), "/usr/bin")

    def test_it_drops_an_empty_entry(self):
        """An empty entry names the directory of work, and not a program."""
        parent = harness_environment(PATH=os.pathsep.join(["", "/usr/bin"]))
        self.assertEqual(agent_path(parent), "/usr/bin")

    def test_it_is_the_path_of_the_system_when_the_harness_holds_it_all(self):
        """A PATH of harness entries alone leaves the agent with nothing."""
        parent = harness_environment(PATH=f"{HARNESS_VENV}/bin")
        entries = agent_path(parent).split(os.pathsep)
        self.assertEqual(entries, ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])


class TheSummary(unittest.TestCase):
    """The line that tells a reader of a run which Python the agent gets."""

    def test_it_names_the_python_on_the_path(self):
        """The question a run must answer is which Python the agent finds."""
        with tempfile.TemporaryDirectory() as directory:
            python = Path(directory) / "python3"
            python.write_text("")
            python.chmod(EXECUTABLE_MODE)
            summary = environment_summary({"PATH": directory})
            self.assertIn(str(python), summary)

    def test_it_says_none_when_the_path_holds_no_python(self):
        """An absent Python is a condition of the machine, and not an error."""
        with tempfile.TemporaryDirectory() as directory:
            self.assertIn("none", environment_summary({"PATH": directory}))


if __name__ == "__main__":
    unittest.main()

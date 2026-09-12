#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_venv.py -- the proof that a run builds the environment of each
instance.

`swebench_run.py` cloned the repository of an instance and it started the
agent. It built no Python environment, and a SWE-bench repository does not
import from a source checkout. So the agent had to build the environment
itself.

In the run of 2026-09-11 that was the largest cost. Of 707 tool calls, 219
were about pip, uv, virtual environments or absent modules. Two instances went
past the limit of one hour in that work, and their transcripts hold lines such
as `ModuleNotFoundError: No module named 'numpy'`.

These tests hold the new behaviour. The driver reads the spec of the instance,
it makes a virtual environment in the clone, it installs the packages of the
spec, and it puts that environment first on the PATH of the agent. An
instance that this machine cannot build is recorded, and the agent does not
start.

No test here makes a virtual environment, and no test here installs a package.
Each test gives the module the stand-in for `subprocess.run` of
`test_fixtures.py`, as `test_swebench_docker.py` does, so the answer is the
same on each machine.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_venv.py
    python3 bench/test_swebench_venv.py
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from swebench_venv import (
    BUILD_SECONDS,
    BUILT,
    CONDA_PACKAGES,
    ClonePathError,
    FAILED,
    REQUIREMENTS_PACKAGES,
    SHELL_COMMAND,
    TIMED_OUT_EXIT_CODE,
    UNSUPPORTED,
    VENV_COMMAND,
    VENV_DIRECTORY,
    build_commands,
    instance_environment,
    instance_path,
    instance_python,
    instance_spec,
    packages_word_list,
    prepare_environment,
    requirements_file,
    unsupported_reason,
    venv_bin,
    venv_python,
)
from test_fixtures import (
    COMMAND_FAILED,
    a_failing_runner,
    a_refusing_runner,
    a_runner,
)

# The names below are the names of a test, and not the names of this machine.
# A test that reads this machine gives a different answer on each machine.
A_REPO = "astropy/astropy"
A_VERSION = "5.1"
# The Python that `uv` builds on this machine, and the one it does not. The
# spec of 77 instances of the Lite split names 3.6, and `uv` has no build of
# 3.6 and no build of 3.7 for macOS arm64.
A_PYTHON = "3.9"
AN_OLD_PYTHON = "3.6"
A_PYTHON_TO_USE_IN_ITS_PLACE = "3.8"
# A spec with the shape that `MAP_REPO_VERSION_TO_SPECS` gives. The lists are
# short, because a test reads the shape and not the list.
A_SPEC = {
    "python": A_PYTHON,
    "pip_packages": ["numpy==1.25.2", "pytest==7.4.0"],
    "install": "python -m pip install -e .[test] --verbose",
    "test_cmd": "pytest -rA",
}
# The spec of an instance that names a requirements file. 125 instances of the
# Lite split do, and django is 114 of them.
A_REPO_WITH_A_REQUIREMENTS_FILE = "django/django"
A_REQUIREMENTS_PATH = "tests/requirements/py3.txt"
A_SPEC_WITH_A_REQUIREMENTS_FILE = {
    "python": A_PYTHON,
    "packages": REQUIREMENTS_PACKAGES,
    "install": "python -m pip install -e .",
}
# The spec of an instance whose `packages` is a word list of conda names. 105
# instances of the Lite split have one: sympy 76, scikit-learn 23, requests 6
# and astropy 2. None of them gets pytest from `pip_packages`, and each of them
# has a test command, so the word list is where its test tools come from.
A_REPO_WITH_A_WORD_LIST = "psf/requests"
A_WORD_LIST_OF_NAMES = ["pytest", "mpmath"]
A_SPEC_WITH_A_WORD_LIST = {
    "python": A_PYTHON,
    "packages": " ".join(A_WORD_LIST_OF_NAMES),
    "install": "python -m pip install .",
    "test_cmd": "pytest -rA",
}
# The `packages` of four scikit-learn instances quotes each name, so a reader
# of the words must read the quotation marks too.
A_QUOTED_WORD_LIST = "'numpy==1.19.2' 'scipy==1.5.2'"
A_QUOTED_WORD_LIST_OF_NAMES = ["numpy==1.19.2", "scipy==1.5.2"]
# The spec of an instance that this machine cannot build. `pre_install` holds
# `apt-get`, which is of linux, and `sed -i 's/x/y/' file`, which the `sed` of
# macOS does not accept. 44 instances of the Lite split have one.
A_SPEC_WITH_A_PRE_INSTALL = {
    "python": A_PYTHON,
    "install": "python -m pip install -e .",
    "pre_install": ["apt-get -y update && apt-get install -y texlive"],
}
# The spec of an instance that wants a Python no build of which exists here.
A_SPEC_WITH_AN_OLD_PYTHON = {
    "python": AN_OLD_PYTHON,
    "pip_packages": ["cython", "numpy==1.19.2"],
    "install": "python -m pip install -v --no-build-isolation -e .",
}
# The tables that the swebench package publishes. Each test gives its own, so
# no test needs that package, and the CI job installs nothing.
A_SPEC_TABLE = {
    A_REPO: {A_VERSION: A_SPEC},
    A_REPO_WITH_A_REQUIREMENTS_FILE: {A_VERSION: A_SPEC_WITH_A_REQUIREMENTS_FILE},
    A_REPO_WITH_A_WORD_LIST: {A_VERSION: A_SPEC_WITH_A_WORD_LIST},
}
A_REQUIREMENTS_TABLE = {A_REPO_WITH_A_REQUIREMENTS_FILE: [A_REQUIREMENTS_PATH]}
# The path of the finding: it reads a file outside the clone.
A_CLIMB = "../../etc/hostname"
# Paths that the table of a repository must never be able to give. Each one
# names a file OUTSIDE the clone, and the clone is the one directory of the
# instance.
BAD_REQUIREMENTS_PATHS = (
    A_CLIMB,                      # the climb: it leaves the clone
    "..",                         # a climb by itself
    "tests/../../../etc/passwd",  # a climb in the middle of a path
    "/etc/hostname",              # an absolute path
)
# What a command that failed wrote to its standard error. `COMMAND_FAILED` is
# the exit code it gave, and `test_fixtures.py` holds that code and the
# stand-in for `subprocess.run` that each test here gives the module.
AN_ERROR_MESSAGE = "ERROR: Could not find a version that satisfies numpy==1.25.2"
# The name of the word list that pip refuses in the tests of that list, and
# what pip writes then. A conda name is not always a name of PyPI.
A_REFUSED_NAME = A_WORD_LIST_OF_NAMES[-1]
A_REFUSED_NAME_MESSAGE = (
    f"ERROR: No matching distribution found for {A_REFUSED_NAME}"
)
# The number of the command that fails, in the tests that make one fail. The
# first command makes the virtual environment, and every command after it
# needs that environment.
THE_FIRST_COMMAND = 1
THE_SECOND_COMMAND = 2


def a_clone(directory):
    """The directory of a cloned repository, below the given directory.

    - directory: a temporary directory of the test.

    The directory is made, because a build command runs in it.
    """
    clone = Path(directory) / "repo"
    clone.mkdir()
    return clone


def a_build(clone, repo=A_REPO, run=None, **choices):
    """Build the environment of one instance, with the tables of a test.

    - clone: the directory of the cloned repository.
    - repo: the name of the repository of the instance.
    - run: the stand-in runner, or None for one that answers yes to each
      command.
    - choices: what the person chose on the command line.
    """
    return prepare_environment(
        clone,
        repo,
        A_VERSION,
        specs=A_SPEC_TABLE,
        requirements_paths=A_REQUIREMENTS_TABLE,
        run=a_runner() if run is None else run,
        **choices,
    )


class TheSpecOfAnInstance(unittest.TestCase):
    """Where the driver reads the environment of an instance."""

    def test_it_reads_the_spec_of_the_repository_and_the_version(self):
        """The official package publishes the environment of each instance.

        Without it the driver would have to guess the Python version and the
        packages of every repository.
        """
        self.assertEqual(instance_spec(A_REPO, A_VERSION, A_SPEC_TABLE), A_SPEC)


class TheInstancesThisMachineCannotBuild(unittest.TestCase):
    """Which instances the driver stops before the agent starts."""

    def test_a_spec_this_machine_can_build_gives_no_reason(self):
        """179 instances of the Lite split are of this group."""
        self.assertIsNone(unsupported_reason(A_SPEC))

    def test_a_python_with_no_build_stops_the_instance(self):
        """`uv` has no CPython 3.6 and no 3.7 build for macOS arm64.

        77 instances of the Lite split want 3.6.
        """
        reason = unsupported_reason(A_SPEC_WITH_AN_OLD_PYTHON)
        self.assertIsNotNone(reason)
        self.assertIn(AN_OLD_PYTHON, reason)

    def test_a_pre_install_stops_the_instance(self):
        """A `pre_install` is written for linux, and this machine is not linux.

        It holds `apt-get`, or a `sed -i` in the form of GNU. 44 instances of
        the Lite split have one.
        """
        reason = unsupported_reason(A_SPEC_WITH_A_PRE_INSTALL)
        self.assertIsNotNone(reason)
        self.assertIn("pre_install", reason)

    def test_a_chosen_python_lets_the_old_group_run(self):
        """The person can try 3.8 for the instances that want 3.6."""
        self.assertIsNone(
            unsupported_reason(
                A_SPEC_WITH_AN_OLD_PYTHON,
                oldest_python=A_PYTHON_TO_USE_IN_ITS_PLACE,
            )
        )

    def test_a_chosen_python_does_not_answer_a_pre_install(self):
        """The two groups are different conditions, and one choice is not both."""
        self.assertIsNotNone(
            unsupported_reason(
                A_SPEC_WITH_A_PRE_INSTALL,
                oldest_python=A_PYTHON_TO_USE_IN_ITS_PLACE,
            )
        )


class ThePythonOfTheEnvironment(unittest.TestCase):
    """Which Python the environment of an instance gets."""

    def test_it_takes_the_python_of_the_spec(self):
        """The tests of the instance were written for that version."""
        self.assertEqual(instance_python(A_SPEC), A_PYTHON)

    def test_it_takes_the_chosen_python_when_there_is_no_build(self):
        """This is the change that the record of the instance must say."""
        self.assertEqual(
            instance_python(
                A_SPEC_WITH_AN_OLD_PYTHON,
                oldest_python=A_PYTHON_TO_USE_IN_ITS_PLACE,
            ),
            A_PYTHON_TO_USE_IN_ITS_PLACE,
        )

    def test_it_names_no_python_when_there_is_no_build_and_no_choice(self):
        """A person who chose nothing leaves the 3.6 group out."""
        self.assertIsNone(instance_python(A_SPEC_WITH_AN_OLD_PYTHON))


class TheRequirementsFileOfAnInstance(unittest.TestCase):
    """How the driver finds the requirements file of a repository.

    `packages: "requirements.txt"` does not name a file at the root of the
    repository. The official harness reads `MAP_REPO_TO_REQS_PATHS` for the
    path, and django keeps its file at `tests/requirements/py3.txt`.
    """

    def test_it_finds_the_file_at_the_path_of_the_table(self):
        """The clone already holds the file, so this asks for no network.

        The answer is the RESOLVED path, because the gate reads that path and
        a command must get the one the gate read.
        """
        with tempfile.TemporaryDirectory() as directory:
            clone = a_clone(directory)
            wanted = clone / A_REQUIREMENTS_PATH
            wanted.parent.mkdir(parents=True)
            wanted.write_text("pytest\n")
            found = requirements_file(
                clone, A_REPO_WITH_A_REQUIREMENTS_FILE, A_REQUIREMENTS_TABLE
            )
            self.assertEqual(found, wanted.resolve())

    def test_it_finds_no_file_when_the_clone_does_not_hold_one(self):
        """A path of the table that the commit of the instance does not have."""
        with tempfile.TemporaryDirectory() as directory:
            found = requirements_file(
                a_clone(directory),
                A_REPO_WITH_A_REQUIREMENTS_FILE,
                A_REQUIREMENTS_TABLE,
            )
        self.assertIsNone(found)


class TheRequirementsPathThatLeavesTheClone(unittest.TestCase):
    """Which paths of the published table can become a path of this machine.

    `MAP_REPO_TO_REQS_PATHS` comes from the `swebench` package, and the driver
    joins each path of it to the clone. A path such as `../../etc/hostname`
    would thus read a file OUTSIDE the clone. So each path must stand inside
    the clone, and `checked_clone_path` is the one gate that says so.
    """

    def bad_table(self, path):
        """The table of paths of a repository, with one bad path in it.

        - path: the path that leaves the clone.
        """
        return {A_REPO_WITH_A_REQUIREMENTS_FILE: [path]}

    def test_it_refuses_a_path_that_leaves_the_clone(self):
        """The clone is the one directory of an instance."""
        for path in BAD_REQUIREMENTS_PATHS:
            with self.subTest(path=path):
                with tempfile.TemporaryDirectory() as directory:
                    with self.assertRaises(ClonePathError):
                        requirements_file(
                            a_clone(directory),
                            A_REPO_WITH_A_REQUIREMENTS_FILE,
                            self.bad_table(path),
                        )

    def test_the_refusal_names_the_path(self):
        """A person corrects the condition only if the message names it."""
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ClonePathError) as refusal:
                requirements_file(
                    a_clone(directory),
                    A_REPO_WITH_A_REQUIREMENTS_FILE,
                    self.bad_table(A_CLIMB),
                )
        self.assertIn(A_CLIMB, str(refusal.exception))

    def test_the_build_refuses_it_too(self):
        """`prepare_environment` is the door that a run goes through.

        A gate that the run does not reach is not a gate.
        """
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ClonePathError):
                prepare_environment(
                    a_clone(directory),
                    A_REPO_WITH_A_REQUIREMENTS_FILE,
                    A_VERSION,
                    specs=A_SPEC_TABLE,
                    requirements_paths=self.bad_table(A_CLIMB),
                    run=a_runner(),
                )


class TheCommandsOfTheBuild(unittest.TestCase):
    """Which commands build the environment of one instance."""

    def commands_of(self, spec, requirements=None):
        """The commands of one spec, in a clone that is not on the disk.

        - spec: the spec of the instance.
        - requirements: the requirements file of the clone, or None.
        """
        return build_commands(Path("/work/repo"), spec, A_PYTHON, requirements)

    def test_it_makes_the_virtual_environment_first(self):
        """Each command after this one needs that environment."""
        self.assertEqual(
            self.commands_of(A_SPEC)[0],
            [*VENV_COMMAND, A_PYTHON, VENV_DIRECTORY],
        )

    def test_it_installs_the_pip_packages_of_the_spec(self):
        """These are the versions the tests of the instance were run with."""
        command = self.commands_of(A_SPEC)[1]
        self.assertIn("pip", command)
        self.assertEqual(command[-len(A_SPEC["pip_packages"]):], A_SPEC["pip_packages"])

    def test_it_installs_the_packages_word_list_of_the_spec(self):
        """105 instances get their test tools from that word list alone."""
        command = self.commands_of(A_SPEC_WITH_A_WORD_LIST)[1]
        self.assertEqual(
            command[-len(A_WORD_LIST_OF_NAMES):], A_WORD_LIST_OF_NAMES
        )

    def test_it_installs_the_word_list_after_the_pip_packages(self):
        """A spec can name both, and the environment needs each of them."""
        commands = self.commands_of(dict(A_SPEC, packages=A_QUOTED_WORD_LIST))
        self.assertEqual(
            commands[2][-len(A_QUOTED_WORD_LIST_OF_NAMES):],
            A_QUOTED_WORD_LIST_OF_NAMES,
        )

    def test_it_installs_with_the_python_of_that_environment(self):
        """A bare `python` would be the Python of this machine.

        The first command makes the environment, so an absolute path cannot
        install into the wrong one.
        """
        self.assertEqual(
            self.commands_of(A_SPEC)[1][0], str(venv_python(Path("/work/repo")))
        )

    def test_it_installs_no_package_when_the_spec_names_none(self):
        """A spec without `pip_packages` gets the environment and the install."""
        commands = self.commands_of(A_SPEC_WITH_A_REQUIREMENTS_FILE)
        self.assertEqual(len(commands), 2)

    def test_it_installs_the_requirements_file_when_the_clone_holds_one(self):
        """Without it the environment has no pytest, and no test can run."""
        requirements = Path("/work/repo") / A_REQUIREMENTS_PATH
        commands = self.commands_of(
            A_SPEC_WITH_A_REQUIREMENTS_FILE, requirements=requirements
        )
        self.assertIn(str(requirements), commands[1])

    def test_it_runs_the_install_command_of_the_spec_last(self):
        """The package of the instance goes in after its dependencies."""
        self.assertEqual(
            self.commands_of(A_SPEC)[-1],
            [*SHELL_COMMAND, A_SPEC["install"]],
        )

    def test_it_runs_the_install_command_through_a_shell(self):
        """The `install` of a spec is a shell line, and not a list.

        A shell of its own is what reads `.[test]` and `&&`, and the runner
        then needs no `shell=True`.
        """
        self.assertEqual(self.commands_of(A_SPEC)[-1][:2], list(SHELL_COMMAND))


class ThePathOfTheAgent(unittest.TestCase):
    """Where the environment of the instance stands on the PATH."""

    def test_the_environment_of_the_instance_goes_first(self):
        """A `python` of the agent must be the Python of the instance."""
        path = instance_path(Path("/work/repo"), "/usr/bin")
        self.assertEqual(path.split(os.pathsep)[0], str(venv_bin("/work/repo")))

    def test_it_keeps_the_other_entries_in_their_order(self):
        """The agent needs `git`, `uv` and the programs of the system."""
        path = instance_path(Path("/work/repo"), os.pathsep.join(["/a", "/b"]))
        self.assertEqual(path.split(os.pathsep)[1:], ["/a", "/b"])

    def test_the_environment_of_the_agent_names_the_virtual_environment(self):
        """A tool that reads `VIRTUAL_ENV` then finds the one of the instance."""
        environment = instance_environment(
            Path("/work/repo"), {"PATH": "/usr/bin", "HOME": "/home/tester"}
        )
        self.assertEqual(
            environment["VIRTUAL_ENV"], str(venv_bin("/work/repo").parent)
        )

    def test_the_environment_of_the_agent_keeps_what_the_agent_needs(self):
        """`swebench_env.py` decides that, and this must not undo it."""
        environment = instance_environment(
            Path("/work/repo"), {"PATH": "/usr/bin", "HOME": "/home/tester"}
        )
        self.assertEqual(environment["HOME"], "/home/tester")


class TheBuildOfAnEnvironment(unittest.TestCase):
    """What the driver reports after it builds one environment."""

    def test_it_says_built_when_every_command_did_its_work(self):
        """The agent starts only for an instance of this group."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(a_clone(directory))
        self.assertEqual(report.status, BUILT)

    def test_it_names_the_python_of_the_environment(self):
        """The record of the instance keeps this, to say which Python ran."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(a_clone(directory))
        self.assertEqual(report.python, A_PYTHON)

    def test_it_measures_the_time_of_the_build(self):
        """The card asks for the time of this step, beside the clone."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(a_clone(directory))
        self.assertGreaterEqual(report.seconds, 0)

    def test_it_runs_the_commands_in_the_clone(self):
        """`uv venv .venv` makes the environment in the directory of work."""
        run = a_runner()
        with tempfile.TemporaryDirectory() as directory:
            clone = a_clone(directory)
            a_build(clone, run=run)
        self.assertEqual(run.calls[0][1].get("cwd"), str(clone))

    def test_it_gives_each_command_the_environment_of_the_instance(self):
        """A build that reads the Python of the harness builds the wrong one."""
        run = a_runner()
        with tempfile.TemporaryDirectory() as directory:
            clone = a_clone(directory)
            a_build(clone, run=run)
        path = run.calls[0][1]["env"]["PATH"]
        self.assertEqual(path.split(os.pathsep)[0], str(venv_bin(clone)))

    def test_it_gives_each_command_a_limit_of_time(self):
        """A pip that waits for a server would hold the whole run open."""
        run = a_runner()
        with tempfile.TemporaryDirectory() as directory:
            a_build(a_clone(directory), run=run)
        self.assertEqual(run.calls[0][1].get("timeout"), BUILD_SECONDS)

    def test_it_says_failed_when_a_command_does_not_do_its_work(self):
        """A failed environment is not a failure of the agent."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(
                a_clone(directory), run=a_failing_runner(THE_SECOND_COMMAND)
            )
        self.assertEqual(report.status, FAILED)

    def test_it_keeps_the_exit_code_of_the_command_that_failed(self):
        """The record of the instance holds this code."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(
                a_clone(directory), run=a_failing_runner(THE_FIRST_COMMAND)
            )
        self.assertEqual(report.exit_code, COMMAND_FAILED)

    def test_it_runs_no_command_after_the_one_that_failed(self):
        """Each command needs the environment that the command before made."""
        run = a_failing_runner(THE_FIRST_COMMAND)
        with tempfile.TemporaryDirectory() as directory:
            a_build(a_clone(directory), run=run)
        self.assertEqual(len(run.calls), 1)

    def test_it_keeps_what_the_command_that_failed_wrote(self):
        """Without it a person cannot tell one failed build from another."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(
                a_clone(directory),
                run=a_failing_runner(
                    THE_FIRST_COMMAND, stderr=AN_ERROR_MESSAGE
                ),
            )
        self.assertIn(AN_ERROR_MESSAGE, report.output)

    def test_a_command_that_is_absent_is_a_failure_and_not_a_stack(self):
        """A machine without `uv` must get a row, and not an exception."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(
                a_clone(directory),
                run=a_failing_runner(
                    THE_FIRST_COMMAND, raises=FileNotFoundError("uv")
                ),
            )
        self.assertEqual(report.status, FAILED)

    def test_a_command_that_is_too_slow_is_a_failure(self):
        """The limit of time must end the build, and not the run."""
        slow = a_failing_runner(
            THE_FIRST_COMMAND,
            raises=subprocess.TimeoutExpired(VENV_COMMAND, BUILD_SECONDS),
        )
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(a_clone(directory), run=slow)
        self.assertEqual(report.exit_code, TIMED_OUT_EXIT_CODE)

    def test_a_failed_build_names_the_command_that_failed(self):
        """A reason without the command tells a reader nothing."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(
                a_clone(directory), run=a_failing_runner(THE_FIRST_COMMAND)
            )
        self.assertIn(VENV_COMMAND[0], report.reason)

    def test_a_build_that_did_its_work_gives_no_reason(self):
        """A reason says why an instance did not run, and this one ran."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(a_clone(directory))
        self.assertIsNone(report.reason)


class TheInstanceThatDoesNotRun(unittest.TestCase):
    """What the driver does with an instance this machine cannot build."""

    def unsupported_build(self, directory, run):
        """Build the instance whose spec holds a `pre_install`.

        - directory: a temporary directory of the test.
        - run: the stand-in runner.
        """
        clone = a_clone(directory)
        return prepare_environment(
            clone,
            A_REPO,
            A_VERSION,
            specs={A_REPO: {A_VERSION: A_SPEC_WITH_A_PRE_INSTALL}},
            requirements_paths=A_REQUIREMENTS_TABLE,
            run=run,
        )

    def test_it_says_unsupported(self):
        """The score must not hold an instance that never ran."""
        with tempfile.TemporaryDirectory() as directory:
            report = self.unsupported_build(directory, a_runner())
        self.assertEqual(report.status, UNSUPPORTED)

    def test_it_runs_no_command(self):
        """An hour of model time must not go to an instance that cannot pass."""
        run = a_runner()
        with tempfile.TemporaryDirectory() as directory:
            self.unsupported_build(directory, run)
        self.assertEqual(run.calls, [])

    def test_it_measures_no_time(self):
        """A step that did not run gives no number, as the record asks."""
        with tempfile.TemporaryDirectory() as directory:
            report = self.unsupported_build(directory, a_runner())
        self.assertIsNone(report.seconds)

    def test_it_says_why(self):
        """A run that leaves out 121 instances must say why it left each out."""
        with tempfile.TemporaryDirectory() as directory:
            report = self.unsupported_build(directory, a_runner())
        self.assertIn("pre_install", report.reason)


class TheRequirementsFileThatIsAbsent(unittest.TestCase):
    """What the driver does when the spec names a file the clone lacks."""

    def test_it_fails_the_build(self):
        """An environment with no pytest cannot run one test of the instance.

        A quiet build would give the agent an environment that looks whole
        and is not.
        """
        run = a_runner()
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(
                a_clone(directory), repo=A_REPO_WITH_A_REQUIREMENTS_FILE, run=run
            )
        self.assertEqual(report.status, FAILED)
        self.assertEqual(run.calls, [])

    def test_it_names_the_path_it_looked_at(self):
        """A person corrects the condition only if the message names it."""
        with tempfile.TemporaryDirectory() as directory:
            report = a_build(
                a_clone(directory), repo=A_REPO_WITH_A_REQUIREMENTS_FILE
            )
        self.assertIn(A_REQUIREMENTS_PATH, report.reason)

    def test_a_conda_file_is_not_a_requirements_file(self):
        """pip cannot read `environment.yml`, and 27 instances name it.

        Those instances get their `pip_packages` and their install command,
        and the build does not stop.
        """
        spec = dict(A_SPEC, packages=CONDA_PACKAGES)
        with tempfile.TemporaryDirectory() as directory:
            clone = a_clone(directory)
            report = prepare_environment(
                clone,
                A_REPO,
                A_VERSION,
                specs={A_REPO: {A_VERSION: spec}},
                requirements_paths=A_REQUIREMENTS_TABLE,
                run=a_runner(),
            )
        self.assertEqual(report.status, BUILT)


class ThePackagesThatPipInstalls(unittest.TestCase):
    """Which `packages` values become the names of a pip command.

    `packages` takes three forms. `requirements.txt` names a file that
    `MAP_REPO_TO_REQS_PATHS` finds, `environment.yml` names a conda file, and
    every other value is a word list of conda package names.
    """

    def test_a_word_list_gives_each_name(self):
        """These names are the test tools of 105 instances of the Lite split."""
        self.assertEqual(
            packages_word_list(A_SPEC_WITH_A_WORD_LIST), A_WORD_LIST_OF_NAMES
        )

    def test_a_quoted_name_is_one_name(self):
        """Four scikit-learn instances write `'numpy==1.19.2' 'scipy==1.5.2'`.

        A reader that breaks the value at each space gives `'numpy==1.19.2'`
        with its quotation marks, and pip has no package of that name.
        """
        self.assertEqual(
            packages_word_list(dict(A_SPEC, packages=A_QUOTED_WORD_LIST)),
            A_QUOTED_WORD_LIST_OF_NAMES,
        )

    def test_a_requirements_file_gives_no_name(self):
        """That value names a file, and pip reads a file with `-r`."""
        self.assertEqual(packages_word_list(A_SPEC_WITH_A_REQUIREMENTS_FILE), [])

    def test_a_conda_file_gives_no_name(self):
        """pip cannot read `environment.yml`, and 27 instances name it."""
        self.assertEqual(
            packages_word_list(dict(A_SPEC, packages=CONDA_PACKAGES)), []
        )

    def test_a_spec_without_packages_gives_no_name(self):
        """Many specs name no `packages` at all."""
        self.assertEqual(packages_word_list(A_SPEC), [])


class TheWordListInABuild(unittest.TestCase):
    """What a run does with a `packages` that is a word list of conda names.

    A conda name is not always a name of PyPI. Each name of the Lite split is
    on PyPI, but the table is published data, so pip can refuse a name. It
    gives an exit code then, and the build stops at that command, as it stops
    at every other command that fails: the record row of the instance names
    the command, it holds the exit code, and it holds what pip wrote. The
    agent does not start with an environment that has no test runner.
    """

    def word_list_build(self, directory, run):
        """Build the instance whose `packages` is a word list.

        - directory: a temporary directory of the test.
        - run: the stand-in runner.
        """
        return a_build(a_clone(directory), repo=A_REPO_WITH_A_WORD_LIST, run=run)

    def refused_build(self, directory):
        """The same build, with a pip that refuses the names of the list.

        - directory: a temporary directory of the test.
        """
        return self.word_list_build(
            directory,
            a_refusing_runner(A_REFUSED_NAME, stderr=A_REFUSED_NAME_MESSAGE),
        )

    def test_the_build_installs_the_names(self):
        """`prepare_environment` is the door that a run goes through.

        A command that only `build_commands` gives is a command no run makes.
        """
        run = a_runner()
        with tempfile.TemporaryDirectory() as directory:
            self.word_list_build(directory, run)
        command = run.calls[1][0]
        self.assertEqual(
            command[-len(A_WORD_LIST_OF_NAMES):], A_WORD_LIST_OF_NAMES
        )

    def test_a_name_that_pip_refuses_stops_the_build(self):
        """An environment with no pytest cannot run one test of the instance."""
        with tempfile.TemporaryDirectory() as directory:
            report = self.refused_build(directory)
        self.assertEqual(report.status, FAILED)

    def test_the_reason_names_each_package_it_tried(self):
        """A person finds the bad name only if the reason holds the names."""
        with tempfile.TemporaryDirectory() as directory:
            report = self.refused_build(directory)
        for name in A_WORD_LIST_OF_NAMES:
            with self.subTest(name=name):
                self.assertIn(name, report.reason)

    def test_it_keeps_what_pip_wrote(self):
        """The message of pip says WHICH name of the list it refused."""
        with tempfile.TemporaryDirectory() as directory:
            report = self.refused_build(directory)
        self.assertIn(A_REFUSED_NAME_MESSAGE, report.output)


if __name__ == "__main__":
    unittest.main()

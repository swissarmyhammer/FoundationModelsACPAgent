"""
test_fixtures.py -- what the tests of this directory share.

`test_swebench_docker.py` and `test_swebench_venv.py` each gave their module a
stand-in for `subprocess.run`, so that no test starts the docker daemon and no
test makes a virtual environment. The two stand-ins were the same code in two
files: each one kept its calls in a list, each one gave a `CompletedProcess`,
and each one could raise in place of an answer. A correction of one left the
other as it was.

So the stand-in stands here, and both files import it. A test of a new module
of the harness imports it too.

This file holds NO test. `unittest discover` reads it, finds no `TestCase` in
it, and runs nothing. It needs the standard library only, as each test of this
directory does, because the CI job of the harness installs nothing.
"""
import subprocess

# The exit code of a command that did its work, and the exit code of one that
# did not. Each module of the harness names the first code for itself, because
# it reads the answer of a real command. These two are what a stand-in gives.
COMMAND_DID_ITS_WORK = 0
COMMAND_FAILED = 1


def a_runner(
    *,
    returncode=COMMAND_DID_ITS_WORK,
    stdout="",
    stderr="",
    raises=None,
    answers_at=None,
):
    """A stand-in for `subprocess.run` that gives one answer.

    - returncode: the exit code of the answer.
    - stdout: what the command writes to standard output.
    - stderr: what the command writes to standard error.
    - raises: the error to raise in place of the answer, or None.
    - answers_at: the number of the call that gets this answer, counted from
      1, or None when EVERY call gets it.

    `answers_at` is for a module that runs a ROW of commands: the call of that
    number gets the answer, and each other call gives `COMMAND_DID_ITS_WORK`
    and writes nothing. A module that runs one command needs no number.

    The stand-in keeps each call in `calls`, as a pair of the command and the
    keywords, so a test can read what the module ran, in which order, and with
    which environment.
    """
    calls = []

    def run(command, **keywords):
        calls.append((list(command), keywords))
        if answers_at is not None and len(calls) != answers_at:
            return subprocess.CompletedProcess(
                list(command), COMMAND_DID_ITS_WORK, "", ""
            )
        if raises is not None:
            raise raises
        return subprocess.CompletedProcess(
            list(command), returncode, stdout, stderr
        )

    run.calls = calls
    return run


def a_failing_runner(number, **answer):
    """A stand-in whose command of the given number does not do its work.

    - number: the number of that command, counted from 1.
    - answer: what that command gives: `stderr`, or `raises`.

    Each other command does its work, so a test can say WHICH step of a build
    fails, and prove that the steps after it do not run.
    """
    return a_runner(answers_at=number, returncode=COMMAND_FAILED, **answer)

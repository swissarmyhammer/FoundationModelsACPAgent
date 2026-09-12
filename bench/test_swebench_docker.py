#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_docker.py -- the proof that the score step asks the daemon.

`swebench_score.py` sent `DOCKER_HOST` to the endpoint of the active context,
and it did no more. But the context answers when the daemon does not run, so
the score step started, every instance failed, and the report said:

    "submitted": 16, "evaluated": 0, "resolved": 0, "errored": [ ... all 16 ... ]

That report reads like a failure of the agent, and docker was the cause.

These tests hold the new behaviour. The score step asks the DAEMON with
`docker info`, and not the context. A daemon that does not answer stops the
step with a message that names the endpoint.

No test here starts docker. Each test gives the module the stand-in for
`subprocess.run` of `test_fixtures.py`, so the answer is the same on a machine
with docker and on a machine without it.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_docker.py
    python3 bench/test_swebench_docker.py
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

from swebench_docker import (
    CONTEXT_COMMAND,
    DEFAULT_SOCKET_HOST,
    HOST_VARIABLE,
    NO_HOST,
    PROBE_COMMAND,
    PROBE_SECONDS,
    daemon_answers,
    ensure_host,
    missing_daemon_message,
)
from test_fixtures import COMMAND_FAILED, a_runner

# The names below are the names of a test, and not the names of this machine.
# A test that reads this machine gives a different answer on each machine.
A_CONTEXT_HOST = "unix:///Users/tester/.docker/run/docker.sock"
A_NAMED_HOST = "tcp://192.168.1.10:2375"
# `COMMAND_FAILED` is the exit code that `docker info` gives when the daemon
# does not answer. This machine gave that code, with `/var/run/docker.sock`
# absent and the context still naming an endpoint. `test_fixtures.py` holds it,
# and it holds the stand-in for `subprocess.run` that each test here gives the
# module.


def an_absent_socket():
    """A path of a socket file that is not there.

    The default socket of docker stands at `/var/run/docker.sock`. A test must
    not read that path, because the answer is then the answer of this machine.
    """
    return Path("/no/such/directory/docker.sock")


class TheEndpointOfDocker(unittest.TestCase):
    """Which endpoint the score step gives to the docker library."""

    def test_it_keeps_the_endpoint_that_the_variable_names(self):
        """A person who sets `DOCKER_HOST` names the daemon to speak to."""
        environment = {HOST_VARIABLE: A_NAMED_HOST}
        host = ensure_host(environment, socket=an_absent_socket(), run=a_runner())
        self.assertEqual(host, A_NAMED_HOST)
        self.assertEqual(environment[HOST_VARIABLE], A_NAMED_HOST)

    def test_it_asks_no_context_when_the_variable_names_an_endpoint(self):
        """The choice of the person wins, so there is nothing more to ask."""
        run = a_runner(stdout=A_CONTEXT_HOST)
        ensure_host(
            {HOST_VARIABLE: A_NAMED_HOST}, socket=an_absent_socket(), run=run
        )
        self.assertEqual(run.calls, [])

    def test_it_uses_the_default_socket_when_that_file_is_there(self):
        """The docker library speaks to this socket without a variable.

        So the variable stays absent, and the endpoint is the socket.
        """
        environment = {}
        with tempfile.TemporaryDirectory() as directory:
            socket = Path(directory) / "docker.sock"
            socket.write_text("")
            host = ensure_host(environment, socket=socket, run=a_runner())
        self.assertEqual(host, DEFAULT_SOCKET_HOST)
        self.assertNotIn(HOST_VARIABLE, environment)

    def test_it_sets_the_variable_from_the_context_when_the_socket_is_absent(self):
        """Docker Desktop puts its socket below the home of the user.

        Without the variable, the docker library then stops with a
        FileNotFoundError.
        """
        environment = {}
        host = ensure_host(
            environment,
            socket=an_absent_socket(),
            run=a_runner(stdout=f"{A_CONTEXT_HOST}\n"),
        )
        self.assertEqual(host, A_CONTEXT_HOST)
        self.assertEqual(environment[HOST_VARIABLE], A_CONTEXT_HOST)

    def test_it_asks_the_active_context_for_that_endpoint(self):
        """The active context is the one that docker itself uses."""
        run = a_runner(stdout=A_CONTEXT_HOST)
        ensure_host({}, socket=an_absent_socket(), run=run)
        self.assertEqual(run.calls[0][0], list(CONTEXT_COMMAND))

    def test_it_names_no_endpoint_when_the_context_names_none(self):
        """An empty answer is no answer, and the variable stays absent."""
        environment = {}
        host = ensure_host(environment, socket=an_absent_socket(), run=a_runner())
        self.assertEqual(host, NO_HOST)
        self.assertNotIn(HOST_VARIABLE, environment)

    def test_it_names_no_endpoint_when_the_context_command_fails(self):
        """A command that failed writes nothing that a reader can use."""
        run = a_runner(returncode=COMMAND_FAILED, stdout=A_CONTEXT_HOST)
        self.assertEqual(
            ensure_host({}, socket=an_absent_socket(), run=run), NO_HOST
        )

    def test_it_names_no_endpoint_when_the_docker_command_is_absent(self):
        """A machine without docker must give a message, and not a stack."""
        run = a_runner(raises=FileNotFoundError("docker"))
        self.assertEqual(
            ensure_host({}, socket=an_absent_socket(), run=run), NO_HOST
        )


class TheQuestionToTheDaemon(unittest.TestCase):
    """How the score step learns that the daemon answers."""

    def test_it_asks_the_daemon_and_not_the_context(self):
        """This is the defect that the task names.

        `docker context inspect` gives an endpoint although the daemon does
        not run. `docker info` speaks to the daemon itself.
        """
        run = a_runner()
        daemon_answers(run=run)
        self.assertEqual(run.calls[0][0], list(PROBE_COMMAND))

    def test_it_answers_yes_when_the_daemon_answers(self):
        """A daemon that runs lets the score step do its work."""
        self.assertIs(daemon_answers(run=a_runner()), True)

    def test_it_answers_no_when_the_daemon_does_not_answer(self):
        """This machine gave exit code 1 with the daemon stopped."""
        self.assertIs(
            daemon_answers(run=a_runner(returncode=COMMAND_FAILED)), False
        )

    def test_it_answers_no_when_the_docker_command_is_absent(self):
        """A machine without docker must give a message, and not a stack."""
        self.assertIs(
            daemon_answers(run=a_runner(raises=FileNotFoundError("docker"))), False
        )

    def test_it_answers_no_when_the_daemon_is_too_slow(self):
        """A daemon that starts can hold the question open.

        The score step must not wait for it without an end.
        """
        slow = a_runner(raises=subprocess.TimeoutExpired(PROBE_COMMAND, PROBE_SECONDS))
        self.assertIs(daemon_answers(run=slow), False)

    def test_it_gives_the_daemon_a_limit_of_time(self):
        """Without a limit, `subprocess.run` waits for as long as it must."""
        run = a_runner()
        daemon_answers(run=run)
        self.assertEqual(run.calls[0][1].get("timeout"), PROBE_SECONDS)


class TheMessageWhenDockerDoesNotRun(unittest.TestCase):
    """What a person reads when the score step stops."""

    def test_it_says_that_docker_must_run(self):
        """The report of the old behaviour named the agent, and not docker."""
        self.assertIn("docker", missing_daemon_message(A_CONTEXT_HOST).lower())

    def test_it_names_the_endpoint_that_the_step_tried(self):
        """A person corrects the condition only if the message names it."""
        self.assertIn(A_CONTEXT_HOST, missing_daemon_message(A_CONTEXT_HOST))

    def test_it_says_that_it_found_no_endpoint_when_there_is_none(self):
        """An empty endpoint in the message tells a reader nothing."""
        message = missing_daemon_message(NO_HOST)
        self.assertIn(HOST_VARIABLE, message)
        self.assertIn(CONTEXT_COMMAND[0], message)


if __name__ == "__main__":
    unittest.main()

"""
swebench_docker.py -- the question that the score step asks docker first.

`swebench_score.py` gives the score with the official SWE-bench harness, and
that harness needs a docker daemon that RUNS.

The score step asked the wrong question. It read the endpoint of the active
docker context, it put that endpoint in `DOCKER_HOST`, and it started. But
`docker context inspect` answers when the daemon does not run: it reads the
configuration of docker, and it speaks to no daemon. So the score step of
2026-09-11 pointed at a socket that was not there, each of the 16 instances
failed, and the report said:

    "submitted": 16, "evaluated": 0, "resolved": 0, "errored": [ ... all 16 ... ]

That report reads like a failure of the agent. Docker was the cause. That
file also shows the older shape of the report: it holds the ids at `errored`.
`swebench_report.py` writes a count there now.

So this module asks the DAEMON. `docker info` speaks to the daemon, and its
exit code is the answer. On the machine of that run, with the daemon stopped,
`docker info` gave exit code 1 while `docker context inspect` gave exit code 0
and an endpoint.

Each function takes the runner as an argument, and the default is
`subprocess.run`. A test thus gives a stand-in, and the answer is the same on
a machine with docker and on a machine without it.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block
of a module that the script imports. This module needs the standard library
only.
"""
import subprocess
from pathlib import Path

# The variable that names the daemon to speak to. The docker library reads it,
# and so does the docker command.
HOST_VARIABLE = "DOCKER_HOST"
# The socket that the docker library uses when the variable says nothing.
DEFAULT_SOCKET = Path("/var/run/docker.sock")
DEFAULT_SOCKET_HOST = "unix:///var/run/docker.sock"
# The answer when no endpoint was found at all.
NO_HOST = ""
# The command that names the endpoint of the active docker context. Docker
# Desktop puts its socket below the home of the user, and this command is how
# a person learns where. The question and the format stand apart, because a
# message names the question alone.
CONTEXT_QUESTION = ("docker", "context", "inspect")
CONTEXT_COMMAND = CONTEXT_QUESTION + ("--format", "{{.Endpoints.docker.Host}}")
# The command that asks the DAEMON, and not the configuration. It fails when
# the daemon does not answer, and that is the whole question of this module.
PROBE_COMMAND = ("docker", "info", "--format", "{{.ServerVersion}}")
# How long each command may take, in seconds. A daemon that starts can hold a
# question open, and the score step must not wait for it without an end.
PROBE_SECONDS = 30
# The exit code of a command that did its work.
COMMAND_DID_ITS_WORK = 0


def command_output(command, run):
    """What one docker command wrote, or nothing when it did not answer.

    - command: the command to give.
    - run: the runner, with the shape of `subprocess.run`.

    A machine without docker raises an OSError here, and a daemon that is too
    slow raises a TimeoutExpired. Both mean the same to a caller: no answer.
    """
    try:
        finished = run(
            command, capture_output=True, text=True, timeout=PROBE_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if finished.returncode != COMMAND_DID_ITS_WORK:
        return None
    return finished.stdout.strip()


def ensure_host(environment, socket=DEFAULT_SOCKET, run=subprocess.run):
    """Choose the endpoint of the daemon, and give it to the docker library.

    - environment: the environment of this process, as a dictionary.
    - socket: the default socket of docker.
    - run: the runner, with the shape of `subprocess.run`.

    Returns the endpoint, or `NO_HOST` when nothing names one.

    The order is the order of docker itself. The variable of the person wins.
    The default socket comes next, and the docker library finds that one with
    no help. The active context is last, and only that answer goes into the
    variable: without it `from_env()` stops with a FileNotFoundError.
    """
    named = environment.get(HOST_VARIABLE)
    if named:
        return named
    if socket.exists():
        return DEFAULT_SOCKET_HOST
    host = command_output(CONTEXT_COMMAND, run) or NO_HOST
    if host:
        environment[HOST_VARIABLE] = host
    return host


def daemon_answers(run=subprocess.run):
    """True when the docker daemon answers.

    - run: the runner, with the shape of `subprocess.run`.

    This is the question that the score step must ask before any other work.
    The endpoint of a context proves nothing, because the configuration
    answers when the daemon does not.
    """
    return command_output(PROBE_COMMAND, run) is not None


def named_endpoint(host):
    """The endpoint, in the words that a message uses.

    - host: the endpoint that `ensure_host` gave.

    An empty endpoint in a message tells a reader nothing, so this says which
    three sources were empty.
    """
    if host:
        return host
    return (
        f"none. {HOST_VARIABLE} is not set, {DEFAULT_SOCKET} is not there, and "
        f"`{' '.join(CONTEXT_QUESTION)}` named no endpoint"
    )


def missing_daemon_message(host):
    """The message that a person reads when the score step stops.

    - host: the endpoint that `ensure_host` gave.

    The message must name the endpoint. Without that name a person cannot
    tell a daemon that is stopped from an endpoint that is wrong.
    """
    return (
        "docker does not answer. The score step needs a docker daemon that "
        "runs, because the SWE-bench harness builds an image for each "
        f"instance.\nthe endpoint it tried: {named_endpoint(host)}\n"
        "start docker, and then give this command again."
    )

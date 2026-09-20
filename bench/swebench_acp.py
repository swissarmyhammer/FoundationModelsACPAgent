"""
swebench_acp.py -- the one long-lived agent of a run, over ACP.

`swebench_run.py` started `acp-agent run` for each instance. That command
makes a process, the process resolves its profile and loads its local models,
it runs ONE turn, and it stops. The models then load again for the next
instance. The README of `bench/` measured that as minutes of each instance,
and the Lite split holds 300 instances.

The package already has a server. `acp-agent acp` speaks ACP on its standard
input and its standard output, it serves many sessions, and it loads its
models one time, when it starts. So the harness is the CLIENT of that server
now: one process for the run, and one session for each instance.

    the harness                         the agent
    -----------                         ---------
    start `acp-agent acp`  ---------->  load the models (minutes, ONE time)
    initialize             ---------->
                           <----------  the version and the capabilities
    for each instance:
      session/new(cwd)     ---------->  open a session in the clone
      session/prompt       ---------->  {} at once
                           <----------  session/update ... (the whole turn)
                           <----------  session/update: idle, stopReason
      session/close        ---------->  free the tree of that instance

THE STOP REASON

`acp-agent run` gave the harness an exit code and nothing more. The wire
gives the STOP REASON of each turn: `end_turn`, `max_tokens`,
`max_turn_requests`, `refusal`, `cancelled`, and the four that this agent
adds -- `_error`, `_no_output`, `_stalled` and `_truncated`. A reason is a free string, so
this module never refuses one it does not know, and the record of the
instance keeps whatever the agent said.

THE ENVIRONMENT IS COMPUTED ONE TIME, BECAUSE THE PROCESS IS STARTED ONE TIME

The agent gives a shell child `Environment.inherit`: the whole environment of
the AGENT PROCESS, with the arguments of the tool call on top. There is no
environment for each session, and there is no reading of a `.venv` below the
session directory. So the PATH of the one process is the only PATH the tests
of an instance can get.

`swebench_run.py` answers that with ONE working root for the run. The clone
of each instance stands at the same path, `<root>/repo`, so
`<root>/repo/.venv/bin` is a constant entry of the PATH and the agent gets it
when it starts. Nothing of a session survives into the next one: the agent
builds the configuration, the instructions, the `AGENTS.md` assembly, the
tool catalog and the sandbox again at every `session/new`, from the directory
of THAT session.

A SPEAKER OF ACP MUST BE FULL DUPLEX

`session/prompt` answers `{}` at once, and the whole turn arrives after it as
`session/update` notifications on the same wire. A client written as
"write one frame, then read one frame" stops for ever on the first
notification. So every read of this module goes through one loop that serves
each frame by its shape: the answer it waits for, a notification, or a
request of the agent.

The harness advertises NO capability, so the agent asks it nothing. A request
that arrives even so gets a `method not found` answer, because an agent that
waits for an answer that never comes holds the whole run open.

Each function that speaks to a real process takes its wire as an argument, so
a test gives a stand-in and needs no agent, no pipe and no model.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block
of a module that the script imports. This module needs the standard library
only.
"""
import json
import os
import select
import signal
import subprocess
import time
from dataclasses import dataclass

# --- the wire ---------------------------------------------------------------
# The version of JSON-RPC that every frame declares.
JSONRPC_VERSION = "2.0"
# One frame is one line of UTF-8, and the line ends with one newline.
FRAME_ENCODING = "utf-8"
FRAME_END = "\n"
FRAME_END_BYTE = b"\n"
# What a peer that writes CRLF puts in front of the newline. The codec of the
# agent removes it, and this removes it too.
CARRIAGE_RETURN = "\r"
# How many bytes one read of the pipe asks for.
READ_BYTES = 65536

# --- the protocol -----------------------------------------------------------
# The protocol version this harness speaks. `acp-agent` serves version 2 and
# no other, and it answers a version it does not serve with the one it does.
PROTOCOL_VERSION = 2
# What the agent writes into its own log as the name of its client.
CLIENT_NAME = "swebench-bench"
CLIENT_VERSION = "1.0.0"
# The methods this harness sends.
INITIALIZE = "initialize"
NEW_SESSION = "session/new"
PROMPT = "session/prompt"
CLOSE_SESSION = "session/close"
CANCEL_SESSION = "session/cancel"
# The notification the agent sends for everything that happens in a turn.
SESSION_UPDATE = "session/update"
# The names of the fields of the frames this module reads and writes.
ID_FIELD = "id"
METHOD_FIELD = "method"
PARAMS_FIELD = "params"
RESULT_FIELD = "result"
ERROR_FIELD = "error"
CODE_FIELD = "code"
MESSAGE_FIELD = "message"
SESSION_ID_FIELD = "sessionId"
UPDATE_FIELD = "update"
UPDATE_KIND_FIELD = "sessionUpdate"
STATE_FIELD = "state"
STOP_REASON_FIELD = "stopReason"
CWD_FIELD = "cwd"
# The update that says the foreground work of a session changed, and the
# state of it that says the turn ended.
STATE_UPDATE = "state_update"
IDLE_STATE = "idle"
# What ends the name of an update that carries a PIECE of something. The
# whole thing arrives as an update of its own, so a reader that wants one
# line for each event of a turn passes over these.
CHUNK_END = "_chunk"
# The stop reason the agent gives when `session/cancel` ended the turn.
CANCELLED = "cancelled"
# The JSON-RPC code of a method that a side does not serve. The harness
# serves none, because it advertises no capability.
METHOD_NOT_FOUND = -32601

# --- the process ------------------------------------------------------------
# The subcommand that serves ACP. Bare `acp-agent` is `run`, which would read
# the standard input as a prompt.
ACP_SUBCOMMAND = "acp"
# How long the handshake may take, in seconds. `initialize` is answered after
# the agent resolves its profile, so this one wait covers the model load and,
# on the first run of a machine, the download of the models.
HANDSHAKE_SECONDS = 3600
# How long `session/new` and `session/close` may take, in seconds. Each one
# reads the configuration layers and the skills of the directory.
SESSION_SECONDS = 600
# How long the harness waits for the turn to end after it sends
# `session/cancel`, in seconds. The agent stops the round it is in and then
# writes its files, and one round of a local model is minutes.
CANCEL_SECONDS = 600
# How long to wait for the process to end by itself, in steps and in seconds
# for each step. This is the same shape the one-shot runner used: ask, wait,
# and then insist.
CLOSE_STEPS = 20
STEP_SECONDS = 0.5

# --- what a person reads ----------------------------------------------------
ANSWER_REFUSED = "`{method}` was refused by the agent: {message} (code {code})"
WIRE_ENDED = (
    "the agent process ended. Its own output is on standard error, above "
    "this line."
)
QUIET_WIRE = "the agent said nothing for {seconds} seconds"
NO_ANSWER = "`{method}` got no answer from the agent in {seconds} seconds"
FRAME_IS_NOT_JSON = "the agent wrote a line that is not a JSON message: {line}"
NO_SUCH_METHOD = "this client serves no `{method}`"
PROCESS_IS_GONE = "the agent process no longer reads its standard input"


class AgentProtocolError(RuntimeError):
    """Something went wrong between the harness and the agent.

    This is the base of the errors of this module, so a caller that wants to
    record one instance as an error and go on with the run catches this one
    name.
    """


class AgentAnswerError(AgentProtocolError):
    """The agent answered a request with a JSON-RPC error.

    The message names the method, because an error without it tells a reader
    of the record nothing about which step of the instance failed.
    """


class AgentGoneError(AgentProtocolError):
    """The agent process ended, so no frame can come.

    A run of many hours must go on when this happens: the instance is an
    error, and the instance after it gets a new process.
    """


@dataclass(frozen=True)
class TurnReport:
    """What one turn of one instance did.

    - stop_reason: why the agent stopped, or None when the turn never
      reached an idle update.
    - timed_out: True when the harness stopped the turn at the limit of the
      instance.
    """

    stop_reason: str | None
    timed_out: bool


def is_idle(params, session_id):
    """True when one `session/update` says the turn of a session ended.

    - params: the parameters of the notification.
    - session_id: the session of the turn the caller waits for.

    One process serves many sessions, so the session is part of the
    question. An idle update of ANOTHER session belongs to another instance.
    """
    if params.get(SESSION_ID_FIELD) != session_id:
        return False
    update = params.get(UPDATE_FIELD) or {}
    return (
        update.get(UPDATE_KIND_FIELD) == STATE_UPDATE
        and update.get(STATE_FIELD) == IDLE_STATE
    )


def is_chunk(update):
    """True when one `session/update` carries a PIECE of something.

    - update: the body of the notification.

    A turn of one hour streams thousands of pieces, and the whole thing
    arrives as an update of its own as well. So a reader of a run that wants
    one line for each event passes over these, and it keeps every line of the
    run readable. A kind the harness does not know is NOT a chunk, so a later
    version of the protocol says all it has to say.
    """
    return str(update.get(UPDATE_KIND_FIELD, "")).endswith(CHUNK_END)


def stop_reason_of(params):
    """The stop reason of one idle `session/update`, or None.

    - params: the parameters of the notification.

    The agent SHOULD name a reason, and the field is optional, so a turn
    that ends with no reason gives None here.
    """
    return (params.get(UPDATE_FIELD) or {}).get(STOP_REASON_FIELD)


class ProcessWire:
    """The ndJSON wire of the agent process, on its pipes.

    The standard output of the agent carries the frames and nothing else,
    and its standard error carries its own log. This wire reads the first
    one, and it leaves the second one to the console of the run.

    A read must be able to stop, so this reads the file descriptor itself
    with `select` and keeps its own buffer. A buffered text stream would
    hold bytes that `select` cannot see.
    """

    def __init__(self, process):
        """Make the wire of one agent process.

        - process: the process, with a pipe on its standard input and a pipe
          on its standard output.
        """
        self._process = process
        self._reader = process.stdout.fileno()
        self._buffer = b""
        self._ended = False
        self._closed = False

    def send(self, text):
        """Write one frame to the agent.

        - text: the JSON message, with no line end.
        """
        try:
            self._process.stdin.write(
                (text + FRAME_END).encode(FRAME_ENCODING)
            )
            self._process.stdin.flush()
        except (OSError, ValueError) as error:
            raise AgentGoneError(PROCESS_IS_GONE) from error

    def receive(self, timeout):
        """The next frame the agent wrote.

        - timeout: how long to wait, in seconds.

        Gives None when the wire ended, and raises a `TimeoutError` when the
        agent said nothing in the time given. A blank line is not a message,
        so this passes over it, exactly as the codec of the agent does.
        """
        deadline = time.monotonic() + max(timeout, 0.0)
        while True:
            line = self._take_line()
            if line is not None:
                if line.strip():
                    return line
                continue
            if self._ended:
                return None
            self._fill(deadline - time.monotonic(), timeout)

    def close(self):
        """Close the wire, end the agent and its children, and give the exit
        code of the agent.

        Closing the standard input is how a client of `acp-agent acp` says it
        is done: the agent stands for as long as its client speaks. The
        signals after it are for a model that does not answer, and they go to
        the whole process group so that no child of a shell call survives to
        hold the working root open.
        """
        if self._closed:
            return self._process.returncode
        self._closed = True
        self._end_input()
        self._end_process()
        return self._process.returncode

    def _take_line(self):
        """The next whole line of the buffer, or None when there is none."""
        end = self._buffer.find(FRAME_END_BYTE)
        if end < 0:
            return None
        line = self._buffer[:end]
        self._buffer = self._buffer[end + 1:]
        return line.decode(FRAME_ENCODING).rstrip(CARRIAGE_RETURN)

    def _fill(self, seconds, timeout):
        """Read more bytes of the standard output of the agent.

        - seconds: how long this read may wait.
        - timeout: the whole wait of the caller, for the message of a
          `TimeoutError`.
        """
        ready, _, _ = select.select([self._reader], [], [], max(seconds, 0.0))
        if not ready:
            raise TimeoutError(QUIET_WIRE.format(seconds=round(timeout)))
        chunk = os.read(self._reader, READ_BYTES)
        if not chunk:
            self._ended = True
            return
        self._buffer += chunk

    def _end_input(self):
        """Close the pipes, which tells the agent that its client is done."""
        for pipe in (self._process.stdin, self._process.stdout):
            try:
                pipe.close()
            except OSError:
                pass

    def _end_process(self):
        """Wait for the agent to end, and insist when it does not."""
        if self._wait_a_while():
            return
        self._signal(signal.SIGTERM)
        if self._wait_a_while():
            return
        self._signal(signal.SIGKILL)
        self._process.wait()

    def _wait_a_while(self):
        """True when the process ended inside the wait of `CLOSE_STEPS`."""
        for _ in range(CLOSE_STEPS):
            if self._process.poll() is not None:
                return True
            time.sleep(STEP_SECONDS)
        return False

    def _signal(self, number):
        """Send one signal to the process group of the agent.

        - number: the signal to send.
        """
        try:
            os.killpg(self._process.pid, number)
        except (ProcessLookupError, PermissionError):
            pass


def start_agent(command, working_directory, environment):
    """Start the agent in `acp` mode, and give the wire to it.

    - command: the path of the `acp-agent` binary.
    - working_directory: the directory the process stands in. The agent
      resolves its profile from the configuration of THIS directory, and it
      writes its shell output store below it, so it must be a directory the
      run owns and not the package.
    - environment: the environment the process gets. It is the environment of
      every shell child of every session, so it carries the PATH of the
      instance.

    The process gets a session of its own, so the whole tree of it can be
    signalled. Its standard error is not a pipe: the log of the agent goes to
    the console of the run, where a reader of a long run wants it.
    """
    process = subprocess.Popen(
        [str(command), ACP_SUBCOMMAND],
        cwd=str(working_directory),
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        start_new_session=True,
    )
    return ProcessWire(process)


class Connection:
    """One ACP conversation with the agent, over a wire of ndJSON frames.

    Every read goes through one loop, because the wire is full duplex: the
    answer of a request, the notifications of a turn, and a request of the
    agent all arrive on it in any order.
    """

    def __init__(self, wire, on_update=None):
        """Make the connection.

        - wire: the wire to the agent. It gives `send`, `receive` and
          `close`.
        - on_update: what to give each `session/update` body to, or None. The
          `--verbose` option of the run reads them here, because
          `acp-agent acp` writes the events of a session to its CLIENT and
          takes no option of its own.
        """
        self._wire = wire
        self._on_update = on_update
        self._last_id = 0
        self._open = True

    @property
    def is_open(self):
        """True while the wire can still carry a frame."""
        return self._open

    def handshake(self):
        """Send `initialize`, and give the answer of the agent.

        Out of process this one wait is also the model load: the agent
        resolves its profile before it answers.
        """
        return self.request(
            INITIALIZE,
            {
                "protocolVersion": PROTOCOL_VERSION,
                "info": {"name": CLIENT_NAME, "version": CLIENT_VERSION},
                "capabilities": {},
            },
            HANDSHAKE_SECONDS,
        )

    def open_session(self, cwd):
        """Open one session, and give its id.

        - cwd: the directory of the session. The agent is the only judge of
          it, and every root of the session comes from it.
        """
        answer = self.request(
            NEW_SESSION, {CWD_FIELD: str(cwd)}, SESSION_SECONDS
        )
        return answer[SESSION_ID_FIELD]

    def close_session(self, session_id):
        """Close one session, so the agent frees the tree of that instance.

        - session_id: the session to close.
        """
        self.request(
            CLOSE_SESSION,
            {SESSION_ID_FIELD: session_id},
            SESSION_SECONDS,
        )

    def turn(self, session_id, prompt, seconds):
        """Run one turn, and say how it ended.

        - session_id: the session of the instance.
        - prompt: the problem statement, which is the whole prompt.
        - seconds: the limit of the instance, in seconds.

        Gives a ``TurnReport``. A turn that goes past the limit is cancelled,
        and the report says so and keeps the stop reason the agent gave.
        """
        identifier = self._ask(
            PROMPT,
            {
                SESSION_ID_FIELD: session_id,
                "prompt": [{"type": "text", "text": prompt}],
            },
        )
        deadline = time.monotonic() + seconds
        try:
            reason = self._follow(session_id, identifier, deadline)
        except TimeoutError:
            return self._stop_turn(session_id, identifier)
        return TurnReport(stop_reason=reason, timed_out=False)

    def request(self, method, params, seconds):
        """Send one request, and give the result of its answer.

        - method: the method to ask for.
        - params: the parameters of the request.
        - seconds: how long to wait for the answer, in seconds.

        Raises ``AgentAnswerError`` when the agent refuses,
        ``AgentGoneError`` when the wire ends first, and a `TimeoutError`
        that names the method when no answer comes in the time given.
        """
        identifier = self._ask(method, params)
        deadline = time.monotonic() + seconds
        while True:
            try:
                message = self._receive(deadline)
            except TimeoutError as error:
                # The wire says only that it was quiet. The reader of a run
                # needs the step: a `session/new` with no answer is a fault
                # of the session start, and not of the turn of the model.
                raise TimeoutError(
                    NO_ANSWER.format(method=method, seconds=round(seconds))
                ) from error
            if self._answers(message, identifier):
                return self._result(method, message)
            self._serve(message)

    def notify(self, method, params):
        """Send one notification, which has no answer.

        - method: the method to name.
        - params: the parameters of the notification.
        """
        self._send(
            {
                "jsonrpc": JSONRPC_VERSION,
                METHOD_FIELD: method,
                PARAMS_FIELD: params,
            }
        )

    def close(self):
        """Close the wire, and give the exit code of the agent."""
        self._open = False
        return self._wire.close()

    def _ask(self, method, params):
        """Send one request, and give the id it carries.

        - method: the method to ask for.
        - params: the parameters of the request.
        """
        self._last_id += 1
        self._send(
            {
                "jsonrpc": JSONRPC_VERSION,
                ID_FIELD: self._last_id,
                METHOD_FIELD: method,
                PARAMS_FIELD: params,
            }
        )
        return self._last_id

    def _follow(self, session_id, identifier, deadline):
        """Read frames until the turn of one session goes idle.

        - session_id: the session of the turn.
        - identifier: the id of the `session/prompt` request, whose `{}`
          answer arrives on this same wire and in no fixed order.
        - deadline: when to stop waiting, on the monotonic clock.

        Gives the stop reason of the turn.
        """
        while True:
            message = self._receive(deadline)
            if self._answers(message, identifier):
                self._result(PROMPT, message)
                continue
            params = self._serve(message)
            if params is not None and is_idle(params, session_id):
                return stop_reason_of(params)

    def _stop_turn(self, session_id, identifier):
        """Cancel a turn that went past the limit, and say how it ended.

        - session_id: the session of the turn.
        - identifier: the id of the `session/prompt` request.

        The agent answers a cancel with the `cancelled` stop reason on an
        idle update, so the report keeps a real reason. An agent that answers
        nothing leaves the wire closed, and the caller then starts a new
        process for the next instance.
        """
        deadline = time.monotonic() + CANCEL_SECONDS
        try:
            self.notify(CANCEL_SESSION, {SESSION_ID_FIELD: session_id})
            reason = self._follow(session_id, identifier, deadline)
        except (TimeoutError, AgentProtocolError):
            self.close()
            return TurnReport(stop_reason=None, timed_out=True)
        return TurnReport(stop_reason=reason, timed_out=True)

    def _send(self, message):
        """Write one message to the wire.

        - message: the JSON-RPC message, as a dictionary.
        """
        try:
            self._wire.send(json.dumps(message))
        except OSError as error:
            self.close()
            raise AgentGoneError(WIRE_ENDED) from error

    def _receive(self, deadline):
        """The next message of the wire.

        - deadline: when to stop waiting, on the monotonic clock.

        Raises ``AgentGoneError`` when the wire ended, and lets a
        `TimeoutError` of the wire go to the caller, which is what says a
        turn went past the limit of its instance.
        """
        text = self._wire.receive(max(deadline - time.monotonic(), 0.0))
        if text is None:
            self.close()
            raise AgentGoneError(WIRE_ENDED)
        try:
            return json.loads(text)
        except ValueError as error:
            raise AgentProtocolError(
                FRAME_IS_NOT_JSON.format(line=text)
            ) from error

    def _answers(self, message, identifier):
        """True when one message is the answer of one request.

        - message: the message to read.
        - identifier: the id of the request.

        A request of the AGENT carries an id too, so the method names it
        apart.
        """
        return (
            message.get(ID_FIELD) == identifier
            and METHOD_FIELD not in message
        )

    def _result(self, method, message):
        """The result of one answer.

        - method: the method that was asked for, for the message of an
          error.
        - message: the answer of the agent.
        """
        refusal = message.get(ERROR_FIELD)
        if refusal is not None:
            raise AgentAnswerError(
                ANSWER_REFUSED.format(
                    method=method,
                    message=refusal.get(MESSAGE_FIELD),
                    code=refusal.get(CODE_FIELD),
                )
            )
        result = message.get(RESULT_FIELD)
        return {} if result is None else result

    def _serve(self, message):
        """Serve one frame that is not the answer the caller waits for.

        - message: the message to serve.

        Gives the parameters of a `session/update`, and None for every other
        frame.
        """
        if ID_FIELD in message and METHOD_FIELD in message:
            self._refuse(message)
            return None
        if message.get(METHOD_FIELD) != SESSION_UPDATE:
            return None
        params = message.get(PARAMS_FIELD) or {}
        if self._on_update is not None:
            self._on_update(params.get(UPDATE_FIELD) or {})
        return params

    def _refuse(self, message):
        """Answer a request of the agent, which this client does not serve.

        - message: the request of the agent.

        The harness advertises no capability, so the agent has nothing to ask
        for. An answer goes back even so, because an agent that waits for one
        holds the whole run open.
        """
        self._send(
            {
                "jsonrpc": JSONRPC_VERSION,
                ID_FIELD: message.get(ID_FIELD),
                ERROR_FIELD: {
                    CODE_FIELD: METHOD_NOT_FOUND,
                    MESSAGE_FIELD: NO_SUCH_METHOD.format(
                        method=message.get(METHOD_FIELD)
                    ),
                },
            }
        )


class AgentServer:
    """The one agent process of a run, and the ACP wire to it.

    The process starts when the FIRST instance needs it, so a run whose
    instances are all done already, or all left out, loads no model. It then
    serves every instance after that one.

    A process that stops is started again, because a run of many hours must
    go on. The instance that met the end of the wire is an error, and the
    instance after it gets a new process.
    """

    def __init__(
        self,
        command,
        working_directory,
        environment,
        *,
        start=start_agent,
        on_update=None,
    ):
        """Make the server.

        - command: the path of the `acp-agent` binary.
        - working_directory: the directory the process stands in.
        - environment: the environment the process gets.
        - start: what makes the wire, with the shape of ``start_agent``. A
          test gives a stand-in here.
        - on_update: what to give each `session/update` body to, or None.
        """
        self._command = command
        self._working_directory = working_directory
        self._environment = environment
        self._start = start
        self._on_update = on_update
        self._connection = None
        self._load_seconds = None
        self._exit_code = None
        self._stops = 0

    @property
    def stops(self):
        """How many processes of this server have ended.

        The record of an instance holds the exit code of an agent that DIED,
        and `null` when the agent is still alive. One process serves many
        instances, so ``exit_code`` alone says nothing about WHICH instance a
        death belongs to. A run reads this count before and after each
        instance, and a count that moved says the death is that instance's.
        """
        return self._stops

    @property
    def load_seconds(self):
        """How long the FIRST start took, or None before any start.

        This is the measurement of the whole change: the handshake is
        answered after the agent resolves its profile and loads its models,
        so this number is what each instance after the first one saves.
        """
        return self._load_seconds

    @property
    def exit_code(self):
        """The exit code of the agent process that ended last, or None."""
        return self._exit_code

    def connection(self):
        """The open connection to the agent, starting the process when there
        is none.

        Raises whatever the handshake raises, and leaves no process behind
        when it does.
        """
        if self._connection is not None and self._connection.is_open:
            return self._connection
        self.stop()
        wire = self._start(
            self._command, self._working_directory, self._environment
        )
        self._connection = Connection(wire, on_update=self._on_update)
        started = time.monotonic()
        try:
            self._connection.handshake()
        except (AgentProtocolError, TimeoutError):
            self.stop()
            raise
        if self._load_seconds is None:
            self._load_seconds = time.monotonic() - started
        return self._connection

    def turn(self, cwd, prompt, seconds):
        """Run one instance: one session, one turn, and then close it.

        - cwd: the directory of the clone of the instance.
        - prompt: the problem statement of the instance.
        - seconds: the limit of the instance, in seconds.

        Gives a ``TurnReport``. A wire that fails stops the process, so the
        instance after this one starts a new one.
        """
        connection = self.connection()
        try:
            session_id = connection.open_session(cwd)
            report = connection.turn(session_id, prompt, seconds)
            if connection.is_open:
                connection.close_session(session_id)
        except (AgentProtocolError, TimeoutError):
            self.stop()
            raise
        if not connection.is_open:
            self.stop()
        return report

    def stop(self):
        """Stop the agent process, and give its exit code.

        This runs at the end of a run, and after a wire that failed. It is
        the same on a process that is already gone.
        """
        connection = self._connection
        self._connection = None
        if connection is not None:
            self._exit_code = connection.close()
            self._stops += 1
        return self._exit_code

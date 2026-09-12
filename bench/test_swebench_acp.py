#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_acp.py -- the proof that a run drives one long-lived agent.

`swebench_run.py` started `acp-agent run` for each instance. The agent loads
its local models when it starts, so a run of 179 instances loaded them 179
times. That is minutes of each instance, and hours of a run.

The package already has a server: `acp-agent acp` speaks ACP on its standard
input and its standard output. So the harness is now the CLIENT of that
server. It starts ONE process for the run, and it opens one session for each
instance.

These tests hold that client. No test here starts the agent, no test here
loads a model, and no test here opens a pipe. Each test gives the client a
stand-in wire with a script of answers, so the frames of the harness are the
thing under test and the answer is the same on each machine.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_acp.py
    python3 bench/test_swebench_acp.py
"""
import json
import unittest

from swebench_acp import (
    AgentAnswerError,
    AgentGoneError,
    AgentServer,
    CANCELLED,
    Connection,
    METHOD_NOT_FOUND,
    PROTOCOL_VERSION,
    is_chunk,
)

# The names below are the names of a test, and not the names of a machine.
A_SESSION = "session-01"
ANOTHER_SESSION = "session-02"
A_CLONE = "/tmp/bench-run/repo"
A_PROBLEM = "The reader drops the header row of a table."
AN_ANSWER_OF_THE_AGENT = "I changed one file."
# The stop reason of a turn that ended by itself, and of one that did not.
END_TURN = "end_turn"
REFUSAL = "refusal"
# What the command line of the agent holds in a test.
AN_AGENT = "/tmp/acp-agent"
A_WORKING_ROOT = "/tmp/bench-run"
AN_ENVIRONMENT = {"PATH": "/tmp/bench-run/repo/.venv/bin:/usr/bin"}
# The limit of one instance, in seconds. A stand-in wire never waits, so the
# value only has to be a number the client can subtract from.
A_LIMIT = 3600
# The code and the message of a JSON-RPC error answer in a test.
AN_ERROR_CODE = -32602
AN_ERROR_MESSAGE = "no such session"
# The id of a request that the AGENT sends to the harness.
AN_INBOUND_REQUEST_ID = 900


def a_frame(message):
    """The text of one ndJSON frame.

    - message: the JSON-RPC message, as a dictionary.
    """
    return json.dumps(message)


def an_answer(identifier, result):
    """The frame of a result answer.

    - identifier: the id of the request this answers.
    - result: what the method gave.
    """
    return a_frame({"jsonrpc": "2.0", "id": identifier, "result": result})


def an_error_answer(identifier, code, message):
    """The frame of an error answer.

    - identifier: the id of the request this answers.
    - code: the JSON-RPC error code.
    - message: what the error says.
    """
    return a_frame(
        {
            "jsonrpc": "2.0",
            "id": identifier,
            "error": {"code": code, "message": message},
        }
    )


def an_update(session_id, update):
    """The frame of one `session/update` notification.

    - session_id: the session the update is about.
    - update: the body of the update.
    """
    return a_frame(
        {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {"sessionId": session_id, "update": update},
        }
    )


def a_chunk(session_id, text):
    """The frame of one chunk of the answer of the agent.

    - session_id: the session the chunk is about.
    - text: the words of the chunk.
    """
    return an_update(
        session_id,
        {
            "sessionUpdate": "agent_message_chunk",
            "messageId": "message-01",
            "content": {"type": "text", "text": text},
        },
    )


def an_idle(session_id, stop_reason):
    """The frame of the idle state update that ends a turn.

    - session_id: the session the update is about.
    - stop_reason: why the work of the agent stopped.
    """
    return an_update(
        session_id,
        {
            "sessionUpdate": "state_update",
            "state": "idle",
            "stopReason": stop_reason,
        },
    )


def a_request_of_the_agent(method):
    """The frame of a request that the AGENT sends to the harness.

    - method: the method it asks for.
    """
    return a_frame(
        {
            "jsonrpc": "2.0",
            "id": AN_INBOUND_REQUEST_ID,
            "method": method,
            "params": {},
        }
    )


class AWire:
    """A stand-in for the wire of the agent, with a script of answers.

    The client writes a frame, and this gives the frames of the answer back.
    A test thus reads what the harness SENT, and it needs no process, no pipe
    and no model.
    """

    def __init__(self, answer):
        """Make the stand-in.

        - answer: a function of one message that gives the frames to send
          back, as a list of texts.
        """
        self.sent = []
        self.closed = False
        self._answer = answer
        self._inbox = []

    def send(self, text):
        """Take one frame from the client, and script the answer to it.

        - text: the frame, with no line end.
        """
        message = json.loads(text)
        self.sent.append(message)
        self._inbox.extend(self._answer(message))

    def receive(self, timeout):
        """Give the next frame of the script.

        - timeout: how long the client waits, in seconds.

        A script with nothing more to say raises a `TimeoutError`, which is
        what a real wire does when the agent is quiet.
        """
        if not self._inbox:
            raise TimeoutError(f"the stand-in wire said nothing in {timeout}s")
        return self._inbox.pop(0)

    def close(self):
        """Close the stand-in, and report no exit code."""
        self.closed = True
        return None

    def methods(self):
        """The name of the method of each frame the client sent."""
        return [message.get("method") for message in self.sent]


class AnEndedWire(AWire):
    """A stand-in wire that ENDS in place of answering.

    A real wire ends when the agent process stops. The client must then say
    the agent is gone, and it must not wait for a frame that cannot come.
    """

    def receive(self, timeout):
        """Report the end of the wire.

        - timeout: how long the client waits, in seconds.
        """
        return None


def a_working_agent(stop_reason=END_TURN, session_id=A_SESSION):
    """An answer function that runs one whole turn with no trouble.

    - stop_reason: why the turn of this agent stops.
    - session_id: the session that `session/new` gives back.
    """

    def answer(message):
        method = message.get("method")
        identifier = message.get("id")
        if method == "initialize":
            return [
                an_answer(
                    identifier,
                    {
                        "protocolVersion": PROTOCOL_VERSION,
                        "info": {"name": "agent", "version": "0.1.0"},
                    },
                )
            ]
        if method == "session/new":
            return [an_answer(identifier, {"sessionId": session_id})]
        if method == "session/prompt":
            return [
                an_answer(identifier, {}),
                a_chunk(session_id, AN_ANSWER_OF_THE_AGENT),
                an_idle(session_id, stop_reason),
            ]
        if method == "session/close":
            return [an_answer(identifier, {})]
        return []

    return answer


def a_quiet_agent(answers_the_cancel=True):
    """An answer function for an agent that never ends its turn by itself.

    - answers_the_cancel: whether the agent ends the turn when the harness
      sends `session/cancel`.

    This is the agent that goes past the limit of the instance. The script
    answers the prompt, and it then says nothing until the cancel.
    """
    working = a_working_agent()

    def answer(message):
        method = message.get("method")
        if method == "session/prompt":
            return [an_answer(message.get("id"), {})]
        if method == "session/cancel":
            if not answers_the_cancel:
                return []
            return [an_idle(A_SESSION, CANCELLED)]
        return working(message)

    return answer


class HandshakeTests(unittest.TestCase):
    """The first frames the harness sends to a new agent process."""

    def test_initialize_names_the_protocol_version_of_the_agent(self):
        """The agent serves version 2 only, and it refuses no other version
        quietly: it answers with the version it serves. So the harness must
        send the version it really speaks, and read the answer."""
        wire = AWire(a_working_agent())
        connection = Connection(wire)

        connection.handshake()

        self.assertEqual(wire.methods(), ["initialize"])
        self.assertEqual(
            wire.sent[0]["params"]["protocolVersion"], PROTOCOL_VERSION
        )

    def test_initialize_names_the_harness_as_the_client(self):
        """The agent writes the name of its client into its own log. A name
        of the harness there is what tells a reader which client drove a
        turn."""
        wire = AWire(a_working_agent())

        Connection(wire).handshake()

        self.assertIn("name", wire.sent[0]["params"]["info"])
        self.assertIn("version", wire.sent[0]["params"]["info"])


class SessionTests(unittest.TestCase):
    """One session for each instance, over the one connection."""

    def test_a_new_session_carries_the_directory_of_the_clone(self):
        """The agent is the only judge of the working directory of a session,
        and it reads it from `session/new`. A session with the wrong
        directory would give the agent the wrong repository."""
        wire = AWire(a_working_agent())
        connection = Connection(wire)
        connection.handshake()

        session_id = connection.open_session(A_CLONE)

        self.assertEqual(session_id, A_SESSION)
        self.assertEqual(wire.sent[-1]["params"]["cwd"], A_CLONE)

    def test_closing_a_session_names_it(self):
        """One process serves 179 instances, so each session must be closed
        when its instance ends. Without that, the agent holds the tree of
        every instance of the run."""
        wire = AWire(a_working_agent())
        connection = Connection(wire)
        connection.handshake()
        session_id = connection.open_session(A_CLONE)

        connection.close_session(session_id)

        self.assertEqual(wire.sent[-1]["method"], "session/close")
        self.assertEqual(wire.sent[-1]["params"]["sessionId"], session_id)

    def test_an_error_answer_names_the_method_that_failed(self):
        """An error of the agent must not read as an empty answer. The
        harness records one instance as an error, and a reader of that record
        needs the method and the words of the agent."""

        def refusing(message):
            if message.get("method") == "session/new":
                return [
                    an_error_answer(
                        message.get("id"), AN_ERROR_CODE, AN_ERROR_MESSAGE
                    )
                ]
            return a_working_agent()(message)

        connection = Connection(AWire(refusing))
        connection.handshake()

        with self.assertRaises(AgentAnswerError) as caught:
            connection.open_session(A_CLONE)

        self.assertIn("session/new", str(caught.exception))
        self.assertIn(AN_ERROR_MESSAGE, str(caught.exception))


class TurnTests(unittest.TestCase):
    """One turn of one instance, and how the harness learns it ended."""

    def a_turn(self, answer, limit=A_LIMIT):
        """Run one whole turn against an answer function.

        - answer: the answer function of the stand-in agent.
        - limit: the limit of the instance, in seconds.

        Returns the pair of the wire and the report of the turn.
        """
        wire = AWire(answer)
        connection = Connection(wire)
        connection.handshake()
        session_id = connection.open_session(A_CLONE)
        return wire, connection.turn(session_id, A_PROBLEM, limit)

    def test_the_prompt_carries_the_problem_statement_as_text(self):
        """The agent gets the problem statement of the instance and nothing
        more. One text content block is the whole prompt, so no quote and no
        length of an argument can change it."""
        wire, _ = self.a_turn(a_working_agent())

        prompt = [m for m in wire.sent if m.get("method") == "session/prompt"]
        self.assertEqual(len(prompt), 1)
        self.assertEqual(
            prompt[0]["params"]["prompt"],
            [{"type": "text", "text": A_PROBLEM}],
        )

    def test_the_turn_ends_at_the_idle_update_and_gives_its_stop_reason(self):
        """`session/prompt` answers `{}` at once, and the turn arrives as
        notifications. The idle state update is the end of the turn, and its
        stop reason is the one fact the one-shot `run` command never gave the
        harness."""
        _, report = self.a_turn(a_working_agent(stop_reason=REFUSAL))

        self.assertEqual(report.stop_reason, REFUSAL)
        self.assertFalse(report.timed_out)

    def test_an_idle_update_of_another_session_does_not_end_the_turn(self):
        """One process serves many sessions, so an update names its session.
        A turn that ended at the idle update of ANOTHER session would report
        a stop reason that belongs to a different instance."""

        def two_sessions(message):
            if message.get("method") == "session/prompt":
                return [
                    an_answer(message.get("id"), {}),
                    an_idle(ANOTHER_SESSION, REFUSAL),
                    an_idle(A_SESSION, END_TURN),
                ]
            return a_working_agent()(message)

        _, report = self.a_turn(two_sessions)

        self.assertEqual(report.stop_reason, END_TURN)

    def test_a_turn_past_the_limit_is_cancelled_and_says_so(self):
        """An agent that goes past the limit of the instance must be stopped,
        and the whole run must go on. The harness sends `session/cancel`, the
        agent answers with the `cancelled` stop reason, and the report says
        the watchdog stopped this instance."""
        wire, report = self.a_turn(a_quiet_agent())

        self.assertIn("session/cancel", wire.methods())
        self.assertEqual(report.stop_reason, CANCELLED)
        self.assertTrue(report.timed_out)

    def test_an_agent_that_does_not_answer_the_cancel_closes_the_wire(self):
        """A cancel the agent never answers must not hold the run open. The
        report then carries no stop reason, and the connection is closed so
        that the next instance starts a new process."""
        wire = AWire(a_quiet_agent(answers_the_cancel=False))
        connection = Connection(wire)
        connection.handshake()
        session_id = connection.open_session(A_CLONE)

        report = connection.turn(session_id, A_PROBLEM, A_LIMIT)

        self.assertIsNone(report.stop_reason)
        self.assertTrue(report.timed_out)
        self.assertFalse(connection.is_open)

    def test_a_wire_that_ends_in_the_turn_says_the_agent_is_gone(self):
        """The agent process can stop in the middle of a turn. The harness
        must say so, and not wait for a frame that cannot come."""
        connection = Connection(AnEndedWire(a_working_agent()))

        with self.assertRaises(AgentGoneError):
            connection.handshake()

        self.assertFalse(connection.is_open)

    def test_each_session_update_reaches_the_reader_of_the_events(self):
        """`acp-agent acp` takes no `--verbose` option, because the events of
        a session go to its CLIENT. The harness is that client now, so the
        `--verbose` option of the run reads them here."""
        seen = []
        wire = AWire(a_working_agent())
        connection = Connection(wire, on_update=seen.append)
        connection.handshake()
        session_id = connection.open_session(A_CLONE)

        connection.turn(session_id, A_PROBLEM, A_LIMIT)

        kinds = [update.get("sessionUpdate") for update in seen]
        self.assertEqual(kinds, ["agent_message_chunk", "state_update"])

    def test_a_request_of_the_agent_gets_an_error_answer(self):
        """The connection is full duplex, so the agent can send a request to
        the harness. The harness serves none of them, and an agent that waits
        for an answer that never comes would hold the whole run open."""

        def asking(message):
            if message.get("method") == "session/prompt":
                return [
                    an_answer(message.get("id"), {}),
                    a_request_of_the_agent("elicitation/create"),
                    an_idle(A_SESSION, END_TURN),
                ]
            return a_working_agent()(message)

        wire, report = self.a_turn(asking)

        answers = [m for m in wire.sent if "error" in m]
        self.assertEqual(len(answers), 1)
        self.assertEqual(answers[0]["id"], AN_INBOUND_REQUEST_ID)
        self.assertEqual(answers[0]["error"]["code"], METHOD_NOT_FOUND)
        self.assertEqual(report.stop_reason, END_TURN)


class UpdateKindTests(unittest.TestCase):
    """Which session updates are worth one line of a run."""

    def test_a_piece_of_a_message_is_a_chunk(self):
        """A turn of one hour streams thousands of pieces, and each whole
        message arrives as an update of its own as well. A run that wrote one
        line for each piece would bury every other line of that run."""
        self.assertTrue(is_chunk({"sessionUpdate": "agent_message_chunk"}))
        self.assertTrue(is_chunk({"sessionUpdate": "agent_thought_chunk"}))
        self.assertTrue(is_chunk({"sessionUpdate": "terminal_output_chunk"}))

    def test_a_whole_update_is_not_a_chunk(self):
        """The updates that a reader of a run wants are the whole ones: the
        tool calls, the plan, and the state of the turn."""
        self.assertFalse(is_chunk({"sessionUpdate": "tool_call_update"}))
        self.assertFalse(is_chunk({"sessionUpdate": "state_update"}))
        self.assertFalse(is_chunk({"sessionUpdate": "plan_update"}))

    def test_an_update_with_no_kind_is_not_a_chunk(self):
        """A kind this harness does not know must still reach the line. The
        protocol adds updates, and a run that hid them would say less than
        the wire said."""
        self.assertFalse(is_chunk({}))


class AgentServerTests(unittest.TestCase):
    """The one process of a run, and what starts it again."""

    def a_server(self, wires):
        """A server that takes the given stand-in wires, in order.

        - wires: the wires to give, one for each start of the process.

        Returns the pair of the server and the list of the starts.
        """
        starts = []

        def start(command, working_directory, environment):
            starts.append((command, working_directory, environment))
            return wires[len(starts) - 1]

        server = AgentServer(
            AN_AGENT, A_WORKING_ROOT, AN_ENVIRONMENT, start=start
        )
        return server, starts

    def test_one_process_serves_every_instance_of_the_run(self):
        """This is the whole point of the card. The agent loads its models
        when it starts, so a second start is minutes the run does not have.
        Three instances must start the process one time."""
        wire = AWire(a_working_agent())
        server, starts = self.a_server([wire])

        for _ in range(3):
            server.turn(A_CLONE, A_PROBLEM, A_LIMIT)

        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0], (AN_AGENT, A_WORKING_ROOT, AN_ENVIRONMENT))
        self.assertEqual(wire.methods().count("initialize"), 1)
        self.assertEqual(wire.methods().count("session/new"), 3)

    def test_each_instance_opens_and_closes_a_session_of_its_own(self):
        """One session for each instance keeps the rounds of one instance out
        of the next one, and closing it gives the memory of that tree back."""
        wire = AWire(a_working_agent())
        server, _ = self.a_server([wire])

        server.turn(A_CLONE, A_PROBLEM, A_LIMIT)

        self.assertEqual(
            wire.methods(),
            [
                "initialize",
                "session/new",
                "session/prompt",
                "session/close",
            ],
        )

    def test_a_process_that_stopped_is_started_again(self):
        """A run of many hours must go on when the agent process dies. The
        instance that met the end of the wire is an error, and the instance
        after it gets a new process."""
        ended = AnEndedWire(a_working_agent())
        working = AWire(a_working_agent())
        server, starts = self.a_server([ended, working])

        with self.assertRaises(AgentGoneError):
            server.turn(A_CLONE, A_PROBLEM, A_LIMIT)
        report = server.turn(A_CLONE, A_PROBLEM, A_LIMIT)

        self.assertEqual(len(starts), 2)
        self.assertTrue(ended.closed)
        self.assertEqual(report.stop_reason, END_TURN)

    def test_it_counts_each_process_that_ended(self):
        """The record of an instance holds the exit code of an agent that
        DIED, and `null` when the agent is still alive.

        One process serves many instances, so the exit code of the last
        process to end says nothing about which instance it died in. The
        count does: a run reads it before and after each instance.
        """
        ended = AnEndedWire(a_working_agent())
        server, _ = self.a_server([ended, AWire(a_working_agent())])
        self.assertEqual(server.stops, 0)

        with self.assertRaises(AgentGoneError):
            server.turn(A_CLONE, A_PROBLEM, A_LIMIT)
        after_the_death = server.stops
        server.turn(A_CLONE, A_PROBLEM, A_LIMIT)

        self.assertEqual(after_the_death, 1)
        self.assertEqual(server.stops, after_the_death)

    def test_the_time_of_the_model_load_is_measured_one_time(self):
        """`initialize` is the wait for the agent to resolve its profile and
        load its models. That number is the measurement of this card: it is
        what each instance after the first one saves."""
        server, _ = self.a_server([AWire(a_working_agent())])
        self.assertIsNone(server.load_seconds)

        server.turn(A_CLONE, A_PROBLEM, A_LIMIT)
        first = server.load_seconds
        server.turn(A_CLONE, A_PROBLEM, A_LIMIT)

        self.assertIsNotNone(first)
        self.assertEqual(server.load_seconds, first)

    def test_stopping_the_server_closes_the_wire(self):
        """The agent holds the working root of the run open, and a run that
        left it alive would hold the memory that the score step needs."""
        wire = AWire(a_working_agent())
        server, _ = self.a_server([wire])
        server.turn(A_CLONE, A_PROBLEM, A_LIMIT)

        server.stop()

        self.assertTrue(wire.closed)


if __name__ == "__main__":
    unittest.main()

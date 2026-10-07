import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import InMemoryTracing
import MCPTestServer
import TelemetryTestSupport
import Testing
import Tracing

@testable import FoundationModelsACPAgent

/// The spans of the agent paths that the request spans do not cover: the
/// slash-command dispatch, the elicitation relay and the MCP server connect.
///
/// Each case makes the agent and the harness inside a `TelemetryCapture`, as
/// ``RequestTracingTests`` does. The Router sessions get the tracer of the
/// capture explicitly, because their work runs in a detached task.
@Suite struct AgentSpanTests {
    /// The label of the scripted fixtures of this suite.
    private static let fixtureLabel = "AgentSpanTests"

    /// The name of the built-in command that lists the commands.
    private static let helpCommandName = "help"

    /// The `command.kind` value of a built-in command.
    private static let builtinCommandKind = "builtin"

    /// The argument text of the traced command. No span and no log record
    /// may hold it.
    private static let commandArguments = "AgentSpanTests-command-arguments"

    /// A command name that no source registers.
    private static let unknownCommandName = "agentspantestsnosuchcommand"

    /// The full type name of the error that refuses an unknown command.
    private static let requestErrorTypeName = String(reflecting: RequestError.self)

    /// The name that the loopback MCP test server mounts under.
    private static let elicitingServerName = "elicitor"

    /// The prompt text of the elicitation case.
    private static let elicitationPromptText = "Run the eliciting tool pass"

    /// The form value that the elicitation case answers with. No span and no
    /// log record may hold it.
    private static let acceptedAnswer = "AgentSpanTests-accepted-answer"

    /// The snippet that runs the form-mode eliciting loopback tool.
    private static let formSnippet =
        "return await tools.\(elicitingServerName).\(ScriptedServer.elicitEchoToolName)({});"

    /// The `elicitation.mode` value of a form-mode elicitation.
    private static let formMode = "form"

    /// The `elicitation.outcome` value of an accepted elicitation.
    private static let acceptOutcome = "accept"

    /// The name of the config MCP server of the connect case.
    private static let configServerName = "configured"

    /// The `mcp.server.transport` value of a stdio server.
    private static let stdioTransport = "stdio"

    /// The name of the client MCP server that cannot connect.
    private static let brokenServerName = "broken"

    /// A command that is not an absolute path, so the server cannot start.
    private static let relativeServerCommand = "agent-span-tests-relative-command"

    /// Makes a scripted fixture inside the capture `context`, with the tracer
    /// of the capture.
    ///
    /// - Parameters:
    ///   - script: The steps that the scripted model plays.
    ///   - context: The context of the capture that must keep the spans.
    ///   - projectConfigYAML: The project `config.yaml`, or `nil` for none.
    ///   - mcpServers: The client MCP servers of `session/new`, or `nil`.
    /// - Returns: The fixture, after `initialize` and `session/new`.
    /// - Throws: Whatever the fixture throws.
    private static func makeTracedFixture(
        script: [ScriptedPassStep],
        context: TelemetryCapture.Context,
        projectConfigYAML: String? = nil,
        mcpServers: [FoundationModelsACP.MCPServer]? = nil
    ) async throws -> ScriptedPromptFixture {
        try await ScriptedPromptFixture.make(
            script: script, label: fixtureLabel, projectConfigYAML: projectConfigYAML,
            mcpServers: mcpServers, tracer: context.tracer)
    }

    /// Expects one span with the name `name`.
    ///
    /// - Parameters:
    ///   - name: The span name.
    ///   - run: The traced run.
    /// - Returns: The span.
    /// - Throws: When the run holds no span with that name.
    private static func requireOneSpan(named name: String, in run: TracedRun) throws -> FinishedInMemorySpan {
        let spans = run.spans(named: name)
        #expect(spans.count == 1)
        return try #require(spans.first)
    }

    /// Expects that `child` is a child of `parent` in the same trace.
    ///
    /// - Parameters:
    ///   - child: The child span.
    ///   - parent: The parent span.
    private static func expectChild(_ child: FinishedInMemorySpan, of parent: FinishedInMemorySpan) {
        #expect(child.traceID == parent.traceID)
        #expect(child.parentSpanID == parent.spanID)
    }

    // MARK: - Slash commands

    /// A `/help` prompt records one command span with the command name and
    /// the kind, as a child of the prompt span. No span holds the argument
    /// text.
    @Test(.timeLimit(.minutes(1)))
    func helpCommandRecordsOneCommandSpanUnderThePromptSpan() async throws {
        let run = try await TelemetryCapture.run(forbidding: [Self.commandArguments]) { context in
            let fixture = try await Self.makeTracedFixture(script: [.endPass], context: context)
            _ = try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(
                    sessionId: fixture.sessionId, text: "/\(Self.helpCommandName) \(Self.commandArguments)"))
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            try await Poll.until("the prompt span ended") {
                context.spans.contains { $0.operationName == ACPAgentTelemetry.SpanName.prompt }
            }
            await fixture.close()
            return TracedRun(sessionId: fixture.sessionId.rawValue, context: context)
        }

        let promptSpan = try Self.requireOneSpan(named: ACPAgentTelemetry.SpanName.prompt, in: run)
        let commandSpan = try Self.requireOneSpan(named: ACPAgentTelemetry.SpanName.command, in: run)
        Self.expectChild(commandSpan, of: promptSpan)
        #expect(
            commandSpan.attributes.get(ACPAgentTelemetry.AttributeKey.commandName) == .string(Self.helpCommandName))
        #expect(
            commandSpan.attributes.get(ACPAgentTelemetry.AttributeKey.commandKind)
                == .string(Self.builtinCommandKind))
    }

    /// An unknown command gives its command span the error status and the
    /// type of the error. The span records no error, because a tracing
    /// backend exports the description of a recorded error, and a
    /// description can hold content.
    @Test(.timeLimit(.minutes(1)))
    func unknownCommandRecordsTheErrorTypeOnItsCommandSpan() async throws {
        let run = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeTracedFixture(script: [.endPass], context: context)
            await #expect(throws: RequestError.self) {
                _ = try await fixture.harness.connection.prompt(
                    AgentClientHarness.makePromptRequest(
                        sessionId: fixture.sessionId, text: "/\(Self.unknownCommandName)"))
            }
            await fixture.close()
            return TracedRun(sessionId: fixture.sessionId.rawValue, context: context)
        }

        let commandSpan = try Self.requireOneSpan(named: ACPAgentTelemetry.SpanName.command, in: run)
        #expect(commandSpan.errors.isEmpty)
        #expect(commandSpan.status?.code == .error)
        #expect(
            commandSpan.attributes.get(ACPAgentTelemetry.AttributeKey.errorType)
                == .string(Self.requestErrorTypeName))
        #expect(
            commandSpan.attributes.get(ACPAgentTelemetry.AttributeKey.commandName)
                == .string(Self.unknownCommandName))
    }

    // MARK: - The elicitation relay

    /// One elicitation round trip records one elicitation span with the mode
    /// and the outcome. The "enter" record of the span is there before the
    /// answer comes, and it carries the trace id and the span id of the span.
    /// No span and no log record holds the message or the answer.
    @Test(.timeLimit(.minutes(1)))
    func elicitationRoundTripRecordsOneElicitationSpanAndAnEnterRecordBeforeTheAnswer() async throws {
        let forbidden = [Self.acceptedAnswer, ScriptedServer.elicitEchoMessage]
        let (run, enterRecordsBeforeAnswer) = try await TelemetryCapture.run(forbidding: forbidden) { context in
            let fixture = try await Self.makeTracedFixture(
                script: ScriptedPromptFixture.makeToolPromptScript(code: Self.formSnippet), context: context,
                mcpServers: [try Self.loopbackServer()])
            _ = try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.elicitationPromptText))
            let pending = try await ElicitationPoll.firstPendingElicitation(in: fixture.session)
            let enterRecordsBeforeAnswer = TracedRun(sessionId: fixture.sessionId.rawValue, context: context)
                .enterRecordCount(forSpanNamed: ACPAgentTelemetry.SpanName.elicitation)
            await MainActor.run {
                fixture.session.acceptElicitation(
                    pending.id,
                    content: .object([ScriptedServer.elicitEchoAnswerField: .string(Self.acceptedAnswer)]))
            }
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            await fixture.close()
            return (TracedRun(sessionId: fixture.sessionId.rawValue, context: context), enterRecordsBeforeAnswer)
        }

        #expect(enterRecordsBeforeAnswer == 1)
        let elicitationSpan = try Self.requireOneSpan(named: ACPAgentTelemetry.SpanName.elicitation, in: run)
        #expect(elicitationSpan.attributes.get(ACPAgentTelemetry.AttributeKey.elicitationMode) == .string(Self.formMode))
        #expect(
            elicitationSpan.attributes.get(ACPAgentTelemetry.AttributeKey.elicitationOutcome)
                == .string(Self.acceptOutcome))
        try run.expectOneEnterRecord(withTheIdsOf: elicitationSpan)
    }

    /// The client MCP server that runs the loopback `mcp-test-server`, whose
    /// tools elicit from the client.
    ///
    /// - Returns: The stdio server.
    /// - Throws: When the built `mcp-test-server` product is not found.
    private static func loopbackServer() throws -> FoundationModelsACP.MCPServer {
        .stdio(
            MCPServerStdio(
                command: AbsolutePath(rawValue: try BuiltProductLocator.mcpTestServerURL().path),
                name: elicitingServerName,
                args: [ServerMode.flagName, ServerMode.loopback.rawValue]))
    }

    // MARK: - The MCP server connect

    /// `session/new` with one config MCP server records one connect span with
    /// the server name and the transport, as a child of the `session/new`
    /// span, and writes one "enter" record with the trace id and the span id
    /// of the connect span.
    @Test(.timeLimit(.minutes(1)))
    func sessionNewRecordsOneConnectSpanForAConfigServer() async throws {
        let serverCommand = try BuiltProductLocator.mcpTestServerURL().path
        let yaml = """
            tools:
              mcp:
                - name: \(Self.configServerName)
                  command: \(serverCommand)
                  args: ["\(ServerMode.flagName)", "\(ServerMode.echo.rawValue)"]
            """
        let run = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeTracedFixture(
                script: [.endPass], context: context, projectConfigYAML: yaml)
            await fixture.close()
            return TracedRun(sessionId: fixture.sessionId.rawValue, context: context)
        }

        let sessionNewSpan = try Self.requireOneSpan(named: ACPAgentTelemetry.SpanName.sessionNew, in: run)
        let connectSpan = try Self.requireOneSpan(named: ACPAgentTelemetry.SpanName.mcpConnect, in: run)
        Self.expectChild(connectSpan, of: sessionNewSpan)
        #expect(
            connectSpan.attributes.get(ACPAgentTelemetry.AttributeKey.mcpServerName) == .string(Self.configServerName))
        #expect(
            connectSpan.attributes.get(ACPAgentTelemetry.AttributeKey.mcpServerTransport)
                == .string(Self.stdioTransport))
        try run.expectOneEnterRecord(withTheIdsOf: connectSpan)
    }

    /// A client server that cannot connect does not stop `session/new`: the
    /// session starts, and its surface keeps a `.failed` outcome for the
    /// server. The connect span of the server has the error status and the
    /// type of the error, as a child of the `session/new` span. The span
    /// records no error.
    @Test(.timeLimit(.minutes(1)))
    func serverThatFailsToConnectRecordsTheErrorTypeOnItsConnectSpan() async throws {
        let brokenServer = FoundationModelsACP.MCPServer.stdio(
            MCPServerStdio(
                command: AbsolutePath(rawValue: Self.relativeServerCommand), name: Self.brokenServerName))
        let (run, outcomes) = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeTracedFixture(
                script: [.endPass], context: context, mcpServers: [brokenServer])
            let outcomes = await fixture.harness.agent.sessions[fixture.sessionId]?.surface.mcpServerOutcomes
            await fixture.close()
            return (TracedRun(sessionId: fixture.sessionId.rawValue, context: context), outcomes)
        }

        #expect(
            outcomes == [
                MCPComposition.ServerOutcome(
                    name: Self.brokenServerName, transport: .stdio, origin: .client,
                    result: .failed(reason: .commandNotAbsolute))
            ])
        let connectSpan = try Self.requireOneSpan(named: ACPAgentTelemetry.SpanName.mcpConnect, in: run)
        #expect(connectSpan.errors.isEmpty)
        #expect(connectSpan.status?.code == .error)
        #expect(connectSpan.attributes.get(ACPAgentTelemetry.AttributeKey.errorType) != nil)
        #expect(
            connectSpan.attributes.get(ACPAgentTelemetry.AttributeKey.mcpServerName) == .string(Self.brokenServerName))
        #expect(run.spans(named: ACPAgentTelemetry.SpanName.sessionNew).contains { $0.spanID == connectSpan.parentSpanID })
    }
}

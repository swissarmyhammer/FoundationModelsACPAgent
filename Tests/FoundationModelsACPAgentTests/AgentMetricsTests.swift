import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import MetricsTestKit
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The metrics of the agent (the approved OpenTelemetry design, items 1 and
/// 4): the prompt count and duration, the active sessions, the slash-command
/// count and the MCP connect failures.
///
/// Each case makes the agent inside a `TelemetryCapture`, so each metric that
/// the agent makes goes to the `TestMetrics` factory of the capture. The case
/// reads each value by the metric name and its dimensions. The Router sessions
/// get the tracer of the capture explicitly, as ``AgentSpanTests`` does.
@Suite struct AgentMetricsTests {
    /// The label of the scripted fixtures of this suite.
    private static let fixtureLabel = "AgentMetricsTests"

    /// The text of the plain prompt. No metric dimension may hold it.
    private static let promptText = "AgentMetricsTests-prompt-text"

    /// The `stop_reason` value of a prompt that ends its turn.
    private static let endTurnStopReason = "end_turn"

    /// The name of the built-in command that lists the commands.
    private static let helpCommandName = "help"

    /// The argument text of the `/help` prompt. No metric dimension may hold
    /// it.
    private static let commandArguments = "AgentMetricsTests-command-arguments"

    /// A command name that no source registers.
    private static let unknownCommandName = "agentmetricstestsnosuchcommand"

    /// The `command.kind` value of a built-in command.
    private static let builtinCommandKind = "builtin"

    /// The `command.kind` value of a command that no source registers.
    private static let unknownCommandKind = "unknown"

    /// The `outcome` value of a command that ran.
    private static let okOutcome = "ok"

    /// The `outcome` value of a command that the agent refused.
    private static let refusedOutcome = "refused"

    /// The `transport` value of a stdio MCP server.
    private static let stdioTransport = "stdio"

    /// The name of the config MCP server that cannot start.
    private static let brokenServerName = "broken"

    /// A command that is not an absolute path, so the server cannot start.
    private static let relativeServerCommand = "relative/mcp-test-server"

    /// The number of sessions that stay open after two `session/new` and one
    /// `session/close`.
    private static let oneOpenSession = 1.0

    /// The answer of the scripted model. No metric dimension may hold it.
    private static let answerText = "AgentMetricsTests-answer-text"

    /// Makes a scripted fixture inside the capture `context`, with the tracer
    /// of the capture.
    ///
    /// - Parameters:
    ///   - context: The context of the capture that must keep the metrics.
    ///   - script: The steps that the scripted model plays.
    /// - Returns: The fixture, after `initialize` and `session/new`.
    /// - Throws: Whatever the fixture throws.
    private static func makeFixture(
        context: TelemetryCapture.Context, script: [ScriptedPassStep] = [.endPass]
    ) async throws -> ScriptedPromptFixture {
        try await ScriptedPromptFixture.make(script: script, label: fixtureLabel, tracer: context.tracer)
    }

    /// The value of each dimension of each metric that the code made in
    /// `context`.
    ///
    /// - Parameter context: The context of the capture of the run.
    /// - Returns: The dimension values, in the order of the metric records.
    private static func dimensionValues(in context: TelemetryCapture.Context) -> [String] {
        context.metricRecords.flatMap(\.dimensions).map(\.value)
    }

    /// Expects that no dimension of a metric of `context` holds `sessionId`.
    ///
    /// - Parameters:
    ///   - sessionId: The session id of the run.
    ///   - context: The context of the capture of the run.
    private static func expectNoSessionIdDimension(_ sessionId: SessionId, in context: TelemetryCapture.Context) {
        #expect(!dimensionValues(in: context).contains { $0.contains(sessionId.rawValue) })
    }

    // MARK: - Prompts

    /// One prompt that ends with `end_turn` adds one to
    /// `prompts{stop_reason=end_turn}` and records one `prompt_duration`
    /// value with the same dimension. No dimension holds the session id, the
    /// prompt text or the answer text.
    @Test(.timeLimit(.minutes(1)))
    func promptThatEndsItsTurnCountsOnePromptAndRecordsOneDuration() async throws {
        let dimensions = [(ACPAgentTelemetry.MetricDimension.stopReason, Self.endTurnStopReason)]
        let metrics = try await TelemetryCapture.run(forbidding: [Self.promptText, Self.answerText]) { context in
            let fixture = try await Self.makeFixture(context: context, script: [.textDelta(Self.answerText), .endPass])
            _ = try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.promptText))
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            try await Poll.until("the prompt duration was recorded") {
                (try? context.metricsFactory.expectTimer(ACPAgentTelemetry.MetricName.promptDuration, dimensions))
                    != nil
            }
            await fixture.close()
            Self.expectNoSessionIdDimension(fixture.sessionId, in: context)
            return context.metricsFactory
        }

        let counter = try metrics.expectCounter(ACPAgentTelemetry.MetricName.prompts, dimensions)
        #expect(counter.totalValue == 1)
        let timer = try metrics.expectTimer(ACPAgentTelemetry.MetricName.promptDuration, dimensions)
        #expect(timer.values.count == 1)
    }

    // MARK: - Active sessions

    /// After two `session/new` and one `session/close`, the last
    /// `active_sessions` value is 1. No dimension holds a session id.
    @Test(.timeLimit(.minutes(1)))
    func twoNewSessionsAndOneCloseLeaveOneActiveSession() async throws {
        let lastValue = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeFixture(context: context)
            let second = try await fixture.harness.connection.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path)))
            _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: fixture.sessionId))
            Self.expectNoSessionIdDimension(fixture.sessionId, in: context)
            Self.expectNoSessionIdDimension(second.sessionId, in: context)
            // Read the gauge before the fixture closes: its close closes the
            // second session too.
            let gauge = try context.metricsFactory.expectGauge(ACPAgentTelemetry.MetricName.activeSessions)
            let lastValue = gauge.lastValue
            await fixture.close()
            return lastValue
        }

        #expect(lastValue == Self.oneOpenSession)
    }

    // MARK: - Slash commands

    /// A `/help` prompt adds one to `commands{command.kind=builtin,outcome=ok}`.
    /// No dimension holds the argument text.
    @Test(.timeLimit(.minutes(1)))
    func helpCommandCountsOneBuiltinCommandThatRan() async throws {
        let metrics = try await TelemetryCapture.run(forbidding: [Self.commandArguments]) { context in
            let fixture = try await Self.makeFixture(context: context)
            _ = try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(
                    sessionId: fixture.sessionId, text: "/\(Self.helpCommandName) \(Self.commandArguments)"))
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            await fixture.close()
            return context.metricsFactory
        }

        let counter = try metrics.expectCounter(
            ACPAgentTelemetry.MetricName.commands,
            [
                (ACPAgentTelemetry.MetricDimension.commandKind, Self.builtinCommandKind),
                (ACPAgentTelemetry.MetricDimension.outcome, Self.okOutcome),
            ])
        #expect(counter.totalValue == 1)
    }

    /// A prompt that names an unknown command adds one to
    /// `commands{command.kind=unknown,outcome=refused}`. No dimension holds the
    /// unknown name, because the set of such names has no bound.
    @Test(.timeLimit(.minutes(1)))
    func unknownCommandCountsOneRefusedCommand() async throws {
        let metrics = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeFixture(context: context)
            await #expect(throws: RequestError.self) {
                _ = try await fixture.harness.connection.prompt(
                    AgentClientHarness.makePromptRequest(
                        sessionId: fixture.sessionId, text: "/\(Self.unknownCommandName)"))
            }
            await fixture.close()
            #expect(!Self.dimensionValues(in: context).contains(Self.unknownCommandName))
            return context.metricsFactory
        }

        let counter = try metrics.expectCounter(
            ACPAgentTelemetry.MetricName.commands,
            [
                (ACPAgentTelemetry.MetricDimension.commandKind, Self.unknownCommandKind),
                (ACPAgentTelemetry.MetricDimension.outcome, Self.refusedOutcome),
            ])
        #expect(counter.totalValue == 1)
    }

    // MARK: - MCP connect failures

    /// A config MCP server that cannot start adds one to
    /// `mcp_connect_failures{transport=stdio}`. No dimension holds the server
    /// name or the command.
    @Test func configServerThatCannotStartCountsOneStdioConnectFailure() async throws {
        let section = MCPToolSection.enabled(servers: [
            MCPServerConfiguration(
                name: Self.brokenServerName,
                transport: .stdio(command: Self.relativeServerCommand, args: [], env: [:]))
        ])

        let metrics = try await TelemetryCapture.run(forbidding: [Self.relativeServerCommand]) { context in
            await #expect(throws: StdioServerProcess.StdioServerProcessError.self) {
                _ = try await MCPComposition.connectServers(section: section, clientServers: [])
            }
            #expect(!Self.dimensionValues(in: context).contains(Self.brokenServerName))
            return context.metricsFactory
        }

        let counter = try metrics.expectCounter(
            ACPAgentTelemetry.MetricName.mcpConnectFailures,
            [(ACPAgentTelemetry.MetricDimension.transport, Self.stdioTransport)])
        #expect(counter.totalValue == 1)
    }
}

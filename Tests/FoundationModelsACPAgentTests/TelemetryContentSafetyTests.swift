import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsExtras
import MCPTestServer
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The proof of the "No content" rule of ``ACPAgentTelemetry`` (the approved
/// OpenTelemetry design, items 4 and 5): no span name, span attribute, span
/// event, recorded error, log message, log metadata value, metric name or
/// metric dimension of the agent carries the content of the client.
///
/// The suite drives the agent over the wire, inside one `TelemetryCapture` of
/// FoundationModelsExtras, through each path that carries content:
/// `initialize`, a `session/new` with a config MCP server, an `AGENTS.md` and
/// an `Instructions.md` that is not text, one prompt with two tool calls and an
/// elicitation round trip, one slash command with arguments, one prompt that
/// the client cancels, one slash command whose render fails, a `session/new`
/// with an http MCP server that cannot connect, and `session/close`. Each
/// text of the client is a marker that cannot occur by chance.
///
/// Two errors hold a marker in their description: the render error of the
/// failing command (the command span and the prompt request span see it),
/// and the connect error of the http MCP server, whose URL holds a marker
/// (the MCP connect span and the `session/new` request span see it). A
/// tracing backend exports a recorded error as an `exception` event that
/// holds the description of the error, thus these errors prove that no span
/// records an error description.
///
/// The capture reads each span name, attribute, event, recorded error and
/// status message, each log message, metadata value and error, and each
/// metric name and dimension, and records an issue for each one that holds a
/// marker. Nothing here names a record to check. Thus a later change that
/// adds a span, a log record or a metric on these paths must obey the rule,
/// with no change to this file. The suite also expects the records of each
/// path, so an empty capture cannot pass.
///
/// The Router sessions get the tracer of the capture explicitly, because
/// their work runs in a detached task. For the same reason, the log records
/// and the metrics that Router and Extras write in that task do not come to
/// the capture. The content-safety tests of those packages prove them.
@Suite struct TelemetryContentSafetyTests {
    /// The label of the scripted fixture of this suite.
    private static let fixtureLabel = "TelemetryContentSafetyTests"

    /// The text of the prompt that runs the tool calls.
    private static let toolPromptText = "tcs-prompt-text-5d1c8e"

    /// The text of the prompt that the client cancels.
    private static let cancelledPromptText = "tcs-cancelled-prompt-text-a47b20"

    /// The answer that the scripted model streams.
    private static let responseText = "tcs-model-response-9e3f61"

    /// The text that the arguments of the first tool call hold.
    private static let toolArgument = "tcs-tool-argument-c28d4a"

    /// The parts of the output of the first tool call. The snippet joins them
    /// when it runs, thus the output is not in the arguments.
    private static let toolOutputParts = ["tcs", "tool", "output", "71b9f0"]

    /// The text between two parts of the tool output.
    private static let toolOutputSeparator = "-"

    /// The argument text of the slash command.
    private static let commandArguments = "tcs-command-arguments-3a6e5d"

    /// The form value that the client answers the elicitation with.
    private static let elicitationAnswer = "tcs-elicitation-answer-f09c17"

    /// The `env` value of the config MCP server.
    private static let envValue = "tcs-mcp-env-value-6b2e84"

    /// The `headers` value of the http MCP server.
    private static let headerValue = "tcs-mcp-header-value-d5a193"

    /// The value in the unknown section of `config.yaml`.
    private static let configValue = "tcs-config-section-value-8c47e2"

    /// The content of the `AGENTS.md` of the working directory.
    private static let agentsFileContent = "tcs-agents-file-content-2f8b6c"

    /// The text in the project `Instructions.md`, whose bytes are not UTF-8.
    private static let unreadableFileContent = "tcs-unreadable-file-content-e61d39"

    /// The bytes before ``unreadableFileContent`` that make the file not
    /// UTF-8.
    private static let notUTF8Bytes: [UInt8] = [0xFF, 0xFE]

    /// The name of the config MCP server: the loopback `mcp-test-server`,
    /// whose tools elicit from the client.
    private static let elicitingServerName = "elicitor"

    /// The name of the http MCP server.
    private static let httpServerName = "remote"

    /// The path of ``unreachableServerURL``. The description of the connect
    /// error holds it.
    private static let unreachableServerPath = "tcs-mcp-url-path-b93e1f"

    /// An http URL where no server listens, so the connect fails.
    private static let unreachableServerURL = "http://127.0.0.1:9/\(unreachableServerPath)"

    /// The name of the slash command whose render fails.
    private static let failingCommandName = "fail"

    /// The argument text of the slash command whose render fails. The
    /// description of the render error holds it.
    private static let failingCommandArguments = "tcs-failing-command-arguments-4c7d2a"

    /// The name of the header that holds ``headerValue``.
    private static let headerName = "Authorization"

    /// The name of the variable that holds ``envValue``.
    private static let envName = "TCS_SECRET"

    /// The name of the unknown section of `config.yaml`.
    private static let unknownSectionName = "tcs_unknown_section"

    /// The number of prompts that the suite sends.
    private static let promptCount = 4

    /// The name of the span of one mounted tool call. FoundationModelsExtras
    /// keeps its vocabulary internal, thus the suite writes the name.
    private static let extrasToolSpanName = "FoundationModelsExtras.tool"

    /// The output of the first tool call.
    private static var toolOutput: String {
        toolOutputParts.joined(separator: toolOutputSeparator)
    }

    /// Each text of the client that no telemetry record may hold.
    private static var forbiddenContent: [String] {
        [
            toolPromptText, cancelledPromptText, responseText, toolArgument, toolOutput, commandArguments,
            elicitationAnswer, ScriptedServer.elicitEchoMessage, envValue, headerValue, configValue,
            agentsFileContent, unreadableFileContent, unreachableServerPath, failingCommandArguments,
        ]
    }

    /// The span names that the driven paths must record.
    private static let expectedSpanNames: Set<String> = [
        ACPAgentTelemetry.SpanName.initialize, ACPAgentTelemetry.SpanName.sessionNew,
        ACPAgentTelemetry.SpanName.prompt, ACPAgentTelemetry.SpanName.command,
        ACPAgentTelemetry.SpanName.elicitation, ACPAgentTelemetry.SpanName.mcpConnect,
        ACPAgentTelemetry.SpanName.cancel, extrasToolSpanName,
    ]

    /// The metric names that the driven paths must record.
    private static let expectedMetricNames: Set<String> = [
        ACPAgentTelemetry.MetricName.prompts, ACPAgentTelemetry.MetricName.promptDuration,
        ACPAgentTelemetry.MetricName.activeSessions, ACPAgentTelemetry.MetricName.commands,
        ACPAgentTelemetry.MetricName.mcpConnectFailures,
    ]

    /// The log metadata keys that the driven paths must record: the client
    /// identity of `initialize`, the unknown section of `config.yaml`, the
    /// `Instructions.md` that is not text, the elicitation and the cancel.
    private static let expectedLogMetadataKeys: Set<String> = [
        ACPAgentTelemetry.LogMetadataKey.clientName, ACPAgentTelemetry.LogMetadataKey.configSection,
        ACPAgentTelemetry.LogMetadataKey.filePath, ACPAgentTelemetry.LogMetadataKey.elicitationId,
        ACPAgentTelemetry.LogMetadataKey.cancelResult,
    ]

    /// No telemetry record of the agent holds a text of the client, and each
    /// driven path records its spans, log records and metrics.
    @Test(.timeLimit(.minutes(1)))
    func noTelemetryRecordCarriesTheContentOfTheClient() async throws {
        try await TelemetryCapture.run(forbidding: Self.forbiddenContent) { context in
            try await Self.driveEachContentPath(in: context)

            #expect(Self.expectedSpanNames.subtracting(context.spans.map(\.operationName)) == [])
            #expect(Self.expectedMetricNames.subtracting(context.metricRecords.map(\.label)) == [])
            #expect(Self.expectedLogMetadataKeys.subtracting(context.logRecords.flatMap(\.metadata.keys)) == [])
        }
    }

    // MARK: - The driven paths

    /// Drives each path that carries content, from `initialize` to the close
    /// of the harness.
    ///
    /// - Parameter context: The context of the capture that must keep the
    ///   telemetry.
    /// - Throws: Whatever the fixture or a request throws.
    private static func driveEachContentPath(in context: TelemetryCapture.Context) async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: try makeScript(), label: fixtureLabel, workingDirectory: try makeWorkingDirectory(),
            projectConfigYAML: try makeConfigYAML(), tracer: context.tracer,
            commandProviders: [StubCommandProvider(commandSet: [failingCommand])])
        try await runToolPrompt(on: fixture)
        try await runPrompt(on: fixture, text: "/\(helpCommandName) \(commandArguments)")
        try await runCancelledPrompt(on: fixture)
        await runFailingCommand(on: fixture)
        try await Poll.until("each prompt span ended") {
            context.spans.count { $0.operationName == ACPAgentTelemetry.SpanName.prompt } == promptCount
        }
        await connectUnreachableServer(on: fixture)
        _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: fixture.sessionId))
        await fixture.close()
    }

    /// The name of the built-in command that lists the commands.
    private static let helpCommandName = "help"

    /// Sends the slash command whose render fails, and expects the refusal.
    /// The description of the refusal holds the argument text, as the
    /// description of the render error does.
    ///
    /// - Parameter fixture: The fixture of the run.
    private static func runFailingCommand(on fixture: ScriptedPromptFixture) async {
        let refusal = await #expect(throws: RequestError.self) {
            _ = try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(
                    sessionId: fixture.sessionId, text: "/\(failingCommandName) \(failingCommandArguments)"))
        }
        #expect(String(describing: refusal).contains(failingCommandArguments))
    }

    /// Sends a `session/new` with the http MCP server where no server
    /// listens, and expects the failure. The description of the failure holds
    /// the path of the URL, as the description of the connect error does.
    ///
    /// - Parameter fixture: The fixture of the run.
    private static func connectUnreachableServer(on fixture: ScriptedPromptFixture) async {
        let failure = await #expect(throws: (any Error).self) {
            _ = try await fixture.harness.connection.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path), mcpServers: [httpServer]))
        }
        #expect(String(describing: failure).contains(unreachableServerPath))
    }

    /// Sends the prompt that runs the two tool calls, answers the
    /// elicitation of the second call, and waits until the prompt ends.
    ///
    /// - Parameter fixture: The fixture of the run.
    /// - Throws: Whatever the prompt or a wait throws.
    private static func runToolPrompt(on fixture: ScriptedPromptFixture) async throws {
        try await runPrompt(on: fixture, text: toolPromptText) {
            let pending = try await ElicitationPoll.firstPendingElicitation(
                of: fixture.sessionId, on: fixture.harness.client)
            await MainActor.run {
                fixture.harness.client.acceptElicitation(
                    pending.id,
                    content: .object([ScriptedServer.elicitEchoAnswerField: .string(elicitationAnswer)]))
            }
        }
    }

    /// Sends the prompt that the model holds, cancels it when it runs, and
    /// waits until it ends.
    ///
    /// - Parameter fixture: The fixture of the run.
    /// - Throws: Whatever the prompt, the cancel or a wait throws.
    private static func runCancelledPrompt(on fixture: ScriptedPromptFixture) async throws {
        let runningBefore = runningCount(in: await fixture.collector.updates)
        try await runPrompt(on: fixture, text: cancelledPromptText) {
            _ = try await ScriptedPromptFixture.waitForUpdates(
                of: fixture.collector, toReach: "the cancelled prompt runs"
            ) { updates in
                runningCount(in: updates) > runningBefore
            }
            try await fixture.harness.connection.sessionCancel(
                CancelSessionNotification(sessionId: fixture.sessionId))
        }
    }

    /// Sends one prompt, runs `whileRunning`, and waits until the prompt ends
    /// and the session takes a new prompt.
    ///
    /// - Parameters:
    ///   - fixture: The fixture of the run.
    ///   - text: The text of the prompt.
    ///   - whileRunning: The work of the client while the prompt runs.
    /// - Throws: Whatever the prompt, `whileRunning` or a wait throws.
    private static func runPrompt(
        on fixture: ScriptedPromptFixture, text: String, whileRunning: () async throws -> Void = {}
    ) async throws {
        let idleBefore = ScriptedPromptFixture.idleCount(in: await fixture.collector.updates)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: text))
        try await whileRunning()
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector, count: idleBefore + 1)
        try await ScriptedPromptFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
    }

    /// The number of running state updates in the sequence.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The count.
    private static func runningCount(in updates: [UpdateSessionNotification]) -> Int {
        updates.count { notification in
            if case .stateUpdate(.running) = notification.update { return true }
            return false
        }
    }

    // MARK: - The fixture content

    /// The script of each pass. The tool prompt runs the marker snippet and
    /// the eliciting snippet, then streams the answer. The model holds the
    /// cancelled prompt until the cancel. Any other pass ends at once.
    ///
    /// - Returns: The script.
    /// - Throws: The arguments-encoding error.
    private static func makeScript() throws -> [ScriptedPassStep] {
        let elicitingSnippet =
            "return await tools.\(elicitingServerName).\(ScriptedServer.elicitEchoToolName)({});"
        let quotedOutputParts = toolOutputParts.map { "\"\($0)\"" }.joined(separator: ", ")
        let markerSnippet =
            "const input = \"\(toolArgument)\"; return [\(quotedOutputParts)].join(\"\(toolOutputSeparator)\");"
        return [
            .onPrompt(
                containing: toolPromptText,
                play: [
                    try ScriptedPromptFixture.makeRunCodeCall(code: markerSnippet),
                    try ScriptedPromptFixture.makeRunCodeCall(code: elicitingSnippet),
                    .textDelta(responseText), .endPass,
                ]),
            .onPrompt(containing: cancelledPromptText, play: [.hold]),
            .endPass,
        ]
    }

    /// The project `config.yaml`: the loopback MCP server with an `env`
    /// value, and an unknown section with a value.
    ///
    /// - Returns: The YAML document.
    /// - Throws: When the built `mcp-test-server` product is not found.
    private static func makeConfigYAML() throws -> String {
        """
        tools:
          mcp:
            - name: \(elicitingServerName)
              command: \(try BuiltProductLocator.mcpTestServerURL().path)
              args: ["\(ServerMode.flagName)", "\(ServerMode.loopback.rawValue)"]
              env:
                \(envName): \(envValue)
        \(unknownSectionName):
          secret: \(configValue)
        """
    }

    /// Makes the working directory of the session, with an `AGENTS.md` that
    /// the assembler reads and a project `Instructions.md` that is not text.
    ///
    /// - Returns: The working directory.
    /// - Throws: The directory-creation or write error.
    private static func makeWorkingDirectory() throws -> URL {
        let cwd = makeResolvedDirectory(label: "\(fixtureLabel)-repo")
        try Data(agentsFileContent.utf8).write(
            to: cwd.appendingPathComponent(InstructionsAssembler.agentsFileName))
        let dotfolder = cwd.appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfolder, withIntermediateDirectories: true)
        try Data(notUTF8Bytes + Array(unreadableFileContent.utf8)).write(
            to: dotfolder.appendingPathComponent(InstructionsAssembler.instructionsFileName))
        return cwd
    }

    /// The client http MCP server, with a secret header, where no server
    /// listens.
    private static var httpServer: FoundationModelsACP.MCPServer {
        .http(
            MCPServerHTTP(
                name: httpServerName, url: unreachableServerURL,
                headers: [HTTPHeader(name: headerName, value: headerValue)]))
    }

    /// The slash command whose render throws a ``RenderFailure`` with the
    /// argument text of the invocation.
    private static var failingCommand: SlashCommand {
        SlashCommand(
            name: failingCommandName,
            description: "fails to render",
            body: .rendered { invocation in
                throw RenderFailure(arguments: invocation.arguments)
            })
    }
}

/// The error of the slash command whose render fails. Its description holds
/// the argument text of the invocation.
private struct RenderFailure: Error {
    /// The argument text of the invocation.
    let arguments: String
}

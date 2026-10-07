import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import MCPTestServer
import Testing

@testable import FoundationModelsACPAgent

/// The `_mcp_server_status` session update (task ^cbqsngc): the encode of
/// one MCP server outcome, and the report that the agent sends after the
/// response of `session/new` and of `session/resume`.
@Suite struct MCPServerStatusReportTests {
    // MARK: - The encode of one outcome

    /// The session id of the JSON examples of the task.
    private static let exampleSessionId = "01K9Z3M4Q8T2V6X0B5C7D9E1F3"

    /// The `params` of the first JSON example of the task: a connected
    /// http server from the client.
    private static let connectedExampleParams = """
        {
          "sessionId": "01K9Z3M4Q8T2V6X0B5C7D9E1F3",
          "update": {
            "sessionUpdate": "_mcp_server_status",
            "name": "github",
            "transport": "http",
            "origin": "client",
            "status": "connected"
          }
        }
        """

    /// The `params` of the second JSON example of the task: a stdio server
    /// from the client whose command is not an absolute path.
    private static let failedExampleParams = """
        {
          "sessionId": "01K9Z3M4Q8T2V6X0B5C7D9E1F3",
          "update": {
            "sessionUpdate": "_mcp_server_status",
            "name": "files",
            "transport": "stdio",
            "origin": "client",
            "status": "failed",
            "reason": "The command is not an absolute path."
          }
        }
        """

    /// The `params` of a connected stdio server from the configuration.
    private static let configExampleParams = """
        {
          "sessionId": "01K9Z3M4Q8T2V6X0B5C7D9E1F3",
          "update": {
            "sessionUpdate": "_mcp_server_status",
            "name": "tools",
            "transport": "stdio",
            "origin": "config",
            "status": "connected"
          }
        }
        """

    /// The `params` of a client server whose transport the agent does not
    /// know: the update has no `transport` member.
    private static let unknownTransportExampleParams = """
        {
          "sessionId": "01K9Z3M4Q8T2V6X0B5C7D9E1F3",
          "update": {
            "sessionUpdate": "_mcp_server_status",
            "name": "socket",
            "origin": "client",
            "status": "failed",
            "reason": "The transport is not known."
          }
        }
        """

    /// The encode of a connected client http server gives the members of
    /// the first JSON example of the task.
    @Test func aConnectedOutcomeEncodesTheMembersOfTheExample() throws {
        let outcome = MCPComposition.ServerOutcome(
            name: "github", transport: .http, origin: .client, result: .connected)

        #expect(try Self.encodedParams(of: outcome) == Self.jsonValue(Self.connectedExampleParams))
    }

    /// The encode of a failed client stdio server gives the members of the
    /// second JSON example of the task, with the reason text.
    @Test func aFailedOutcomeEncodesTheReasonOfTheExample() throws {
        let outcome = MCPComposition.ServerOutcome(
            name: "files", transport: .stdio, origin: .client,
            result: .failed(reason: .commandNotAbsolute))

        #expect(try Self.encodedParams(of: outcome) == Self.jsonValue(Self.failedExampleParams))
    }

    /// The encode of a server from the configuration gives `"origin":
    /// "config"`.
    @Test func aConfigOutcomeEncodesTheConfigOrigin() throws {
        let outcome = MCPComposition.ServerOutcome(
            name: "tools", transport: .stdio, origin: .config, result: .connected)

        #expect(try Self.encodedParams(of: outcome) == Self.jsonValue(Self.configExampleParams))
    }

    /// The encode of a server whose transport the agent does not know has
    /// no `transport` member.
    @Test func anOutcomeWithNoKnownTransportEncodesNoTransportMember() throws {
        let outcome = MCPComposition.ServerOutcome(
            name: "socket", transport: nil, origin: .client,
            result: .failed(reason: .unknownTransport))

        #expect(
            try Self.encodedParams(of: outcome) == Self.jsonValue(Self.unknownTransportExampleParams))
    }

    /// A client decodes the encoded update as the unknown update kind
    /// `_mcp_server_status`, with the members as its payload. No change to
    /// FoundationModelsACP is necessary.
    @Test func theEncodedUpdateDecodesAsTheUnknownUpdateKind() throws {
        let outcome = MCPComposition.ServerOutcome(
            name: "github", transport: .http, origin: .client, result: .connected)
        let data = try JSONEncoder().encode(Self.notification(of: outcome))

        let decoded = try JSONDecoder().decode(UpdateSessionNotification.self, from: data)

        let payload = try #require(Self.statusPayload(of: decoded.update))
        #expect(payload[MCPServerStatusReport.MemberName.name] == .string("github"))
        #expect(payload[MCPServerStatusReport.MemberName.status] == .string("connected"))
    }

    // MARK: - The report of session/new

    /// The label of the fixtures of this suite.
    private static let fixtureLabel = "MCPServerStatusReportTests"

    /// The name of the loopback `mcp-test-server` of the client. The name is
    /// the noun of the tools of the server, so it is an identifier.
    private static let loopbackServerName = "statusLoopback"

    /// The name of the client stdio server whose command is relative.
    private static let brokenServerName = "statusBroken"

    /// A command that is not an absolute path, so the server cannot start.
    private static let relativeServerCommand = "mcp-server-status-report-tests-relative-command"

    /// The text of the prompt that proves the session works.
    private static let promptText = "MCPServerStatusReportTests-prompt"

    /// The text that the scripted model answers.
    private static let answerText = "MCPServerStatusReportTests-answer"

    /// The client stdio server that runs the loopback `mcp-test-server`.
    ///
    /// - Returns: The server.
    /// - Throws: When the built `mcp-test-server` product is not found.
    private static func loopbackServer() throws -> FoundationModelsACP.MCPServer {
        .stdio(
            MCPServerStdio(
                command: AbsolutePath(rawValue: try BuiltProductLocator.mcpTestServerURL().path),
                name: loopbackServerName,
                args: [ServerMode.flagName, ServerMode.loopback.rawValue]))
    }

    /// A client stdio server whose command is not an absolute path.
    ///
    /// - Parameters:
    ///   - name: The server name.
    ///   - args: The command arguments.
    ///   - env: The environment of the command.
    /// - Returns: The server.
    private static func relativeServer(
        named name: String, args: [String] = [], env: [EnvVariable] = []
    ) -> FoundationModelsACP.MCPServer {
        .stdio(
            MCPServerStdio(
                command: AbsolutePath(rawValue: relativeServerCommand), name: name, args: args, env: env))
    }

    /// Wires a scripted fixture with a tap on the client end of the wire,
    /// and opens one session with `mcpServers`.
    ///
    /// - Parameters:
    ///   - mcpServers: The client MCP servers of `session/new`, or `nil`.
    ///   - projectConfigYAML: The project `config.yaml`, or `nil`.
    /// - Returns: The fixture.
    /// - Throws: Whatever the fixture throws.
    private static func makeFixture(
        mcpServers: [FoundationModelsACP.MCPServer]?, projectConfigYAML: String? = nil
    ) async throws -> ScriptedPromptFixture {
        try await ScriptedPromptFixture.make(
            loader: makeScriptedModelLoader(script: [.textDelta(answerText), .endPass]),
            label: fixtureLabel,
            projectConfigYAML: projectConfigYAML,
            mcpServers: mcpServers,
            tapsWire: true)
    }

    /// After the `session/new` response, the client gets one status update
    /// for each server in mount order: `connected` for the loopback server
    /// and `failed` for the server whose command is relative. No status
    /// update comes before the response, and the session answers a prompt.
    @Test(.timeLimit(.minutes(1)))
    func sessionNewReportsEachServerAfterTheResponse() async throws {
        let fixture = try await Self.makeFixture(
            mcpServers: [try Self.loopbackServer(), Self.relativeServer(named: Self.brokenServerName)])
        let payloads = try await Self.waitForStatusPayloads(in: fixture.collector, count: 2)
        let wireLines = try await Self.wireLines(of: fixture)

        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.promptText))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(
            payloads == [
                Self.payload(name: Self.loopbackServerName, transport: "stdio", status: "connected"),
                Self.payload(
                    name: Self.brokenServerName, transport: "stdio", status: "failed",
                    reason: MCPComposition.ServerOutcome.FailureReason.commandNotAbsolute.rawValue),
            ])
        let responseIndex = try #require(Self.sessionResponseIndices(in: wireLines).first)
        let statusIndices = Self.statusLineIndices(in: wireLines)
        #expect(statusIndices.count == 2)
        #expect(statusIndices.allSatisfy { $0 > responseIndex })
        #expect(ScriptedPromptFixture.agentText(in: updates) == Self.answerText)
    }

    /// A client server whose name an earlier server has is refused, and the
    /// report gives it `failed` with the collision reason.
    @Test(.timeLimit(.minutes(1)))
    func aNameCollisionReportsTheCollisionReason() async throws {
        let fixture = try await Self.makeFixture(
            mcpServers: [
                Self.relativeServer(named: Self.brokenServerName),
                Self.relativeServer(named: Self.brokenServerName),
            ])
        let payloads = try await Self.waitForStatusPayloads(in: fixture.collector, count: 2)
        await fixture.close()

        #expect(
            payloads.map { $0[MCPServerStatusReport.MemberName.reason] } == [
                .string(MCPComposition.ServerOutcome.FailureReason.commandNotAbsolute.rawValue),
                .string(MCPComposition.ServerOutcome.FailureReason.nameCollision.rawValue),
            ])
    }

    /// `mcp: false` refuses each client server, and the report gives it
    /// `failed` with the `mcp: false` reason.
    @Test(.timeLimit(.minutes(1)))
    func mcpOffReportsTheMCPOffReason() async throws {
        let fixture = try await Self.makeFixture(
            mcpServers: [Self.relativeServer(named: Self.brokenServerName)],
            projectConfigYAML: "tools:\n  mcp: false\n")
        let payloads = try await Self.waitForStatusPayloads(in: fixture.collector, count: 1)
        await fixture.close()

        #expect(
            payloads == [
                Self.payload(
                    name: Self.brokenServerName, transport: "stdio", status: "failed",
                    reason: MCPComposition.ServerOutcome.FailureReason.mcpDisabled.rawValue)
            ])
    }

    /// A session with no MCP server sends no status update: a prompt after
    /// `session/new` ends, and the wire holds no status update.
    @Test(.timeLimit(.minutes(1)))
    func aSessionWithNoServerSendsNoStatusUpdate() async throws {
        let fixture = try await Self.makeFixture(mcpServers: nil)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.promptText))
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        let wireLines = try await Self.wireLines(of: fixture)
        await fixture.close()

        #expect(Self.statusLineIndices(in: wireLines).isEmpty)
    }

    // MARK: - No secret in the report

    /// The `env` value of the stdio server.
    private static let envValue = "msr-env-value-5d1c7a"

    /// The argument of the stdio server.
    private static let argumentValue = "msr-argument-value-9e3b20"

    /// The `headers` value of the http server.
    private static let headerValue = "msr-header-value-4f8a61"

    /// The path of the URL of the http server.
    private static let urlPath = "msr-url-path-c27e93"

    /// The name of the http server where no server listens.
    private static let unreachableServerName = "statusUnreachable"

    /// An http server where no server listens, with a secret in its URL and
    /// in its headers.
    private static var unreachableServer: FoundationModelsACP.MCPServer {
        .http(
            MCPServerHTTP(
                name: unreachableServerName, url: "http://127.0.0.1:9/\(urlPath)",
                headers: [HTTPHeader(name: "Authorization", value: headerValue)]))
    }

    /// No status update holds the URL, an argument, an `env` value or a
    /// `headers` value of a server. The reason is the fixed text.
    @Test(.timeLimit(.minutes(1)))
    func noStatusUpdateHoldsASecretOfTheServer() async throws {
        let fixture = try await Self.makeFixture(
            mcpServers: [
                Self.unreachableServer,
                Self.relativeServer(
                    named: Self.brokenServerName, args: [Self.argumentValue],
                    env: [EnvVariable(name: "MSR_SECRET", value: Self.envValue)]),
            ])
        let payloads = try await Self.waitForStatusPayloads(in: fixture.collector, count: 2)
        let wireLines = try await Self.wireLines(of: fixture)
        await fixture.close()

        #expect(
            payloads.map { $0[MCPServerStatusReport.MemberName.reason] } == [
                .string(MCPComposition.ServerOutcome.FailureReason.connectFailed.rawValue),
                .string(MCPComposition.ServerOutcome.FailureReason.commandNotAbsolute.rawValue),
            ])
        let statusLines = Self.statusLineIndices(in: wireLines).map { wireLines[$0] }
        #expect(statusLines.count == 2)
        for secret in [Self.envValue, Self.argumentValue, Self.headerValue, Self.urlPath] {
            #expect(!statusLines.contains { $0.contains(secret) })
        }
    }

    // MARK: - The report of session/resume

    /// After the `session/resume` response, the client gets a new report for
    /// the servers of the resume request. The replay before the response
    /// holds no old status update, and the retained history holds none.
    @Test(.timeLimit(.minutes(1)))
    func sessionResumeSendsANewReportAndTheReplayHoldsNoStatusUpdate() async throws {
        var resume = try await ResumeSessionFixture.make(
            label: "\(Self.fixtureLabel)-resume",
            mcpServers: [Self.relativeServer(named: Self.brokenServerName)],
            tapsWire: true)
        _ = try await Self.waitForStatusPayloads(in: resume.fixture.collector, count: 1)
        try await resume.runPrompt(Self.promptText)
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: try resume.recordingRoot, sessionId: resume.fixture.sessionId, count: 1)
        await resume.fixture.harness.agent.markSessionClosed(resume.fixture.sessionId)
        var request = resume.makeResumeRequest(replayFrom: .start(ReplayFromStart()))
        request.mcpServers = [Self.relativeServer(named: Self.brokenServerName)]

        _ = try await resume.fixture.harness.connection.resumeSession(request)
        _ = try await Self.waitForStatusPayloads(in: resume.fixture.collector, count: 2)
        let wireLines = try await Self.wireLines(of: resume.fixture)
        let history = await resume.fixture.harness.agent.sessions[resume.fixture.sessionId]?.history
        await resume.fixture.close()

        let responseIndices = Self.sessionResponseIndices(in: wireLines)
        #expect(responseIndices.count == 2)
        let resumeResponseIndex = try #require(responseIndices.last)
        let statusIndices = Self.statusLineIndices(in: wireLines)
        #expect(statusIndices.count { $0 < resumeResponseIndex } == 1)
        #expect(statusIndices.count { $0 > resumeResponseIndex } == 1)
        #expect(Self.userMessageLineCount(in: wireLines) == 2)
        let retained = try #require(history)
        #expect(!(retained.transcriptUpdates + retained.stateUpdates).contains { Self.statusPayload(of: $0) != nil })
    }

    // MARK: - Helpers

    /// The notification that carries the update of `outcome`, in the session
    /// of the JSON examples.
    ///
    /// - Parameter outcome: The outcome to report.
    /// - Returns: The notification.
    private static func notification(of outcome: MCPComposition.ServerOutcome) -> UpdateSessionNotification {
        UpdateSessionNotification(
            sessionId: SessionId(rawValue: exampleSessionId),
            update: MCPServerStatusReport.update(for: outcome))
    }

    /// The encoded `params` of the update of `outcome`, as a JSON value.
    ///
    /// - Parameter outcome: The outcome to report.
    /// - Returns: The JSON value.
    /// - Throws: Whatever the encode or the decode throws.
    private static func encodedParams(of outcome: MCPComposition.ServerOutcome) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(notification(of: outcome)))
    }

    /// The JSON value of `text`.
    ///
    /// - Parameter text: The JSON text.
    /// - Returns: The JSON value.
    /// - Throws: Whatever the decode throws.
    private static func jsonValue(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The payload of `update` when it is a status update, else `nil`.
    ///
    /// - Parameter update: The session update.
    /// - Returns: The members of the payload.
    private static func statusPayload(of update: SessionUpdate) -> [String: JSONValue]? {
        guard case .unknown(MCPServerStatusReport.updateKind, .object(let members)) = update else {
            return nil
        }
        return members
    }

    /// The payload that the report gives for one client server.
    ///
    /// - Parameters:
    ///   - name: The server name.
    ///   - transport: The transport text.
    ///   - status: The status text.
    ///   - reason: The reason text, or `nil` for none.
    /// - Returns: The members of the payload.
    private static func payload(
        name: String, transport: String, status: String, reason: String? = nil
    ) -> [String: JSONValue] {
        var members: [String: JSONValue] = [
            MCPServerStatusReport.MemberName.name: .string(name),
            MCPServerStatusReport.MemberName.transport: .string(transport),
            MCPServerStatusReport.MemberName.origin: .string("client"),
            MCPServerStatusReport.MemberName.status: .string(status),
        ]
        members[MCPServerStatusReport.MemberName.reason] = reason.map { .string($0) }
        return members
    }

    /// Waits until the collector holds `count` status updates, and returns
    /// their payloads in arrival order.
    ///
    /// - Parameters:
    ///   - collector: The collector to poll.
    ///   - count: The number of status updates to wait for.
    /// - Returns: The payloads.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitForStatusPayloads(
        in collector: UpdateCollector, count: Int
    ) async throws -> [[String: JSONValue]] {
        let updates = try await ScriptedPromptFixture.waitForUpdates(
            of: collector, toReach: "\(count) status update(s)"
        ) { updates in
            updates.count { statusPayload(of: $0.update) != nil } >= count
        }
        return updates.compactMap { statusPayload(of: $0.update) }
    }

    /// The lines that the agent sent to the client, in wire order.
    ///
    /// - Parameter fixture: The fixture whose harness taps the wire.
    /// - Returns: The lines.
    /// - Throws: When the harness has no tap.
    private static func wireLines(of fixture: ScriptedPromptFixture) async throws -> [String] {
        await (try #require(fixture.harness.wireTap)).lines
    }

    /// The JSON object of one wire line, or `nil` when the line is not a
    /// JSON object.
    ///
    /// - Parameter line: The wire line.
    /// - Returns: The members of the object.
    private static func object(of line: String) -> [String: JSONValue]? {
        guard case .object(let members) = try? jsonValue(line) else {
            return nil
        }
        return members
    }

    /// The `sessionUpdate` value of a `session/update` line, or `nil`.
    ///
    /// - Parameter line: The wire line.
    /// - Returns: The update kind.
    private static func updateKind(of line: String) -> String? {
        guard let message = object(of: line), message["method"] == .string("session/update"),
            case .object(let params)? = message["params"],
            case .object(let update)? = params["update"],
            case .string(let kind)? = update["sessionUpdate"]
        else {
            return nil
        }
        return kind
    }

    /// The indices of the status update lines.
    ///
    /// - Parameter lines: The wire lines.
    /// - Returns: The indices, in wire order.
    private static func statusLineIndices(in lines: [String]) -> [Int] {
        lines.indices.filter { updateKind(of: lines[$0]) == MCPServerStatusReport.updateKind }
    }

    /// The number of `user_message` update lines.
    ///
    /// - Parameter lines: The wire lines.
    /// - Returns: The count.
    private static func userMessageLineCount(in lines: [String]) -> Int {
        lines.count { updateKind(of: $0) == "user_message" }
    }

    /// The indices of the responses of `session/new` and `session/resume`:
    /// each response whose result holds `configOptions`.
    ///
    /// - Parameter lines: The wire lines.
    /// - Returns: The indices, in wire order.
    private static func sessionResponseIndices(in lines: [String]) -> [Int] {
        lines.indices.filter { index in
            guard case .object(let result)? = object(of: lines[index])?["result"] else {
                return false
            }
            return result["configOptions"] != nil
        }
    }
}

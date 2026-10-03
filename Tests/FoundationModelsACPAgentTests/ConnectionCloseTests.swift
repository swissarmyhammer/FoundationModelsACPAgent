import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import MCPTestServer
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The close of the open sessions when the connection ends with no
/// `session/close` (plan.md §10.1).
///
/// A client can drop the wire at any time: it closes the standard input of
/// a stdio agent, or a host lets the transport go. The agent then runs the
/// `session/close` path for each open session itself. It finishes the shell
/// stream, shuts the MCP servers down, and writes `session-history.json`.
/// Then the agent goes, and gives back its models. Without that path, the
/// agent goes first, and the `SurfaceRefresher` of a session that mounts a
/// server goes while its watch task runs: Multitool then stops the debug
/// build (task `^56jbp35`).
///
/// No case here sends `session/close`. Each case drops the client end of the
/// wire, so the agent end reads the end of its input.
@Suite struct ConnectionCloseTests {
    /// The directory label of the fixture of the mounted session.
    private static let fixtureLabel = "ConnectionCloseTests-mounted"

    /// The name of the client-supplied MCP server, and so its noun.
    private static let serverName = "dropped"

    /// The text of the prompt.
    private static let promptText = "Say hello."

    /// The answer the scripted model gives.
    private static let answerText = "Hello."

    /// The close reason name of a client that closed its end of the wire.
    private static let endOfInputName = "endOfInput"

    /// The close reason name of a transport whose input stream failed.
    private static let transportFailedName = "transportFailed"

    /// The close reason name of a connection that the agent side closed.
    private static let closedLocallyName = "closedLocally"

    /// The error of a failed input stream in the reason-name case.
    private struct StreamFailure: Error {}

    @Test(.timeLimit(.minutes(1)))
    func aDroppedWireClosesAnOpenMountedSessionWritesItsHistoryAndReleasesTheAgent() async throws {
        weak var served: RoutedACPAgent?
        weak var routerSession: (any RoutedSession)?
        let transcriptDirectory: URL
        do {
            let fixture = try await Self.makeMountedFixture()
            let agent = fixture.harness.agent
            served = agent
            let entry = try #require(await agent.sessions[fixture.sessionId])
            routerSession = entry.session
            transcriptDirectory = entry.transcriptDirectory
            _ = try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.promptText))
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            try await ScriptedPromptFixture.waitForAvailability(agent, fixture.sessionId)
            // The end of the prompt wrote the history. The case removes the
            // file, so only the close path of the dropped wire can write it
            // again.
            try FileManager.default.removeItem(
                at: transcriptDirectory.appendingPathComponent(SessionHistoryFile.fileName))
            await Self.dropClientEnd(of: fixture.harness)
        }

        try await Poll.until("the agent is released") { served == nil }
        try await Poll.until("the Router session is released") { routerSession == nil }
        #expect(try SessionHistoryFile.read(from: transcriptDirectory) != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aDroppedWireWritesOneNoticeThatNamesTheEndOfInput() async throws {
        let reasonKey = ACPAgentTelemetry.LogMetadataKey.connectionCloseReason
        let records = try await TelemetryCapture.run(forbidding: []) { context in
            let harness = try await AgentClientHarness.makeRecording()
            _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
            await Self.dropClientEnd(of: harness)
            await harness.agent.waitForConnectionTeardown()
            return context.logRecords
        }

        let closeRecords = records.filter { $0.metadata[reasonKey] != nil }
        #expect(closeRecords.count == 1)
        let record = try #require(closeRecords.first)
        #expect(record.level == .notice)
        #expect(record.metadata[reasonKey] == .string(Self.endOfInputName))
    }

    @Test func eachCloseReasonHasItsCaseName() {
        #expect(RoutedACPAgent.connectionCloseReasonName(.endOfInput) == Self.endOfInputName)
        #expect(
            RoutedACPAgent.connectionCloseReasonName(.transportFailed(StreamFailure()))
                == Self.transportFailedName)
        #expect(RoutedACPAgent.connectionCloseReasonName(.closedLocally) == Self.closedLocallyName)
    }

    /// Wires a scripted fixture whose one session mounts the `mcp-test-server`
    /// executable in echo mode, so the session has a running
    /// `SurfaceRefresher`.
    ///
    /// - Returns: The fixture.
    /// - Throws: Whatever the wiring throws.
    private static func makeMountedFixture() async throws -> ScriptedPromptFixture {
        let server = FoundationModelsACP.MCPServer.stdio(
            MCPServerStdio(
                command: AbsolutePath(rawValue: try BuiltProductLocator.mcpTestServerURL().path),
                name: serverName,
                args: [ServerMode.flagName, ServerMode.echo.rawValue]))
        return try await ScriptedPromptFixture.make(
            script: [.textDelta(answerText), .endPass], label: fixtureLabel, mcpServers: [server])
    }

    /// Drops the client end of the wire with no `session/close`: the client
    /// connection closes, and the wire closes, so the agent end reads the end
    /// of its input. The agent connection is not closed here.
    ///
    /// - Parameter harness: The harness whose client goes away.
    private static func dropClientEnd(of harness: AgentClientHarness) async {
        await harness.connection.close()
        harness.wire.close()
    }
}

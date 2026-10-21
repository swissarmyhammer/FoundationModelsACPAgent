import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// One agent with a connection table (ACPA-5, D120 a): one `RoutedACPAgent`
/// serves each bound connection at the same time, and a later bind adds a
/// connection and does not replace the earlier one.
@Suite(.closesHarnesses) struct ConnectionTableTests {
    /// The text of each prompt. The stub model echoes it.
    private static let promptText = "Say hello."

    /// Two connections bound to one agent each make a session and prompt it.
    /// The updates of each session go out on the connection that made the
    /// session, and the bind of the second connection does not take the
    /// updates of the first.
    @Test
    func eachSessionOfTwoBoundConnectionsUpdatesItsOwnConnection() async throws {
        let agent = try await AgentClientHarness.makeAgent()
        let first = await AgentClientHarness.makeRecording(agent: agent)
        let second = await AgentClientHarness.makeRecording(agent: agent)
        let firstSession = try await Self.openSession(on: first, label: "ConnectionTableTests-first")
        let secondSession = try await Self.openSession(on: second, label: "ConnectionTableTests-second")
        let collectors = try [#require(first.collector), #require(second.collector)]

        _ = try await first.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: firstSession, text: Self.promptText))
        let firstReceiver = try await Self.indexOfCollector(receivingIdleOf: firstSession, among: collectors)
        _ = try await second.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: secondSession, text: Self.promptText))
        let secondReceiver = try await Self.indexOfCollector(receivingIdleOf: secondSession, among: collectors)

        #expect(firstReceiver == 0)
        #expect(secondReceiver == 1)
    }

    /// Each bound connection keeps the client capabilities of its own
    /// `initialize`: a second `initialize` on another connection does not
    /// change the capabilities of the first, and each bind gets its own id.
    @Test
    func eachBoundConnectionKeepsTheCapabilitiesOfItsOwnInitialize() async throws {
        let agent = try await AgentClientHarness.makeAgent()
        let first = await AgentClientHarness.makeRecording(agent: agent)
        let second = await AgentClientHarness.makeRecording(agent: agent)

        _ = try await first.connection.initialize(AgentClientHarness.makeInitializeRequest())
        _ = try await second.connection.initialize(
            AgentClientHarness.makeInitializeRequest(capabilities: ClientCapabilities()))

        #expect(first.routedConnection.id != second.routedConnection.id)
        #expect(first.routedConnection.clientCapabilities?.supportsElicitation == true)
        #expect(second.routedConnection.clientCapabilities?.supportsElicitation == false)
        #expect(agent.clientCapabilities(of: .direct) == nil)
    }

    /// Initializes the client of `harness` and opens one session over its
    /// wire, in a new folder.
    ///
    /// - Parameters:
    ///   - harness: The harness whose client opens the session.
    ///   - label: The prefix of the name of the new folder.
    /// - Returns: The id of the new session.
    /// - Throws: Whatever the wire throws.
    private static func openSession(on harness: AgentClientHarness, label: String) async throws -> SessionId {
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let response = try await harness.connection.newSession(
            AgentClientHarness.makeNewSessionRequest(cwd: makeResolvedDirectory(label: label)))
        return response.sessionId
    }

    /// The index of the collector that first gets an `idle` update of
    /// `sessionId`. An update goes out on one connection only, so the waits
    /// race, and the first one to end names the connection.
    ///
    /// - Parameters:
    ///   - sessionId: The session whose `idle` to wait for.
    ///   - collectors: The collector of each connection.
    /// - Returns: The index of the collector in `collectors`.
    /// - Throws: ``ConditionWaitCancelled`` when the task of the test is
    ///   cancelled before an `idle` comes.
    private static func indexOfCollector(
        receivingIdleOf sessionId: SessionId, among collectors: [UpdateCollector]
    ) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            for (index, collector) in collectors.enumerated() {
                group.addTask {
                    _ = try await collector.wait(for: "the idle of \(sessionId.rawValue)") { updates in
                        ScriptedPromptFixture.idleCount(in: updates.filter { $0.sessionId == sessionId }) >= 1
                    }
                    return index
                }
            }
            let receiver = try #require(try await group.next())
            group.cancelAll()
            return receiver
        }
    }
}

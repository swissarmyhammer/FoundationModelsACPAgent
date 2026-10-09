import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

/// `ComposedAgent`, the public composition of the library: a host composes the
/// agent one time, and then binds it to each `AgentSideConnection` it makes.
///
/// The suite uses the public surface only. It does not use `@testable`, so a
/// pass shows that a package which links the library can do the same.
struct ComposedAgentTests {
    /// The dotfolder name of the host in this suite. It is not the name of
    /// the `acp-agent` executable, so the composition does not depend on it.
    private static let dotfolderName = "composed-agent-host"

    /// The environment variable that roots the user configuration layer. The
    /// suite sets it, so no composition touches the real home directory.
    private static let configHomeVariable = "XDG_CONFIG_HOME"

    /// Composes the agent over the stub model, with each configuration root
    /// in a throwaway directory.
    ///
    /// - Parameter label: The directory label, so a leftover directory says
    ///   where it came from.
    /// - Returns: The composition.
    /// - Throws: Whatever the composition throws.
    private static func composeStubAgent(label: String) async throws -> ComposedAgent {
        let configHome = makeResolvedDirectory(label: "\(label)-config")
        let workspace = makeResolvedDirectory(label: "\(label)-repo")
        let environment = try StubAgentDefaultsLayer.makeEnvironment(
            name: dotfolderName, base: [configHomeVariable: configHome.path])
        return try await ComposedAgent.compose(
            name: DotfolderName(dotfolderName),
            workingDirectory: workspace,
            environment: environment,
            modelSource: .stub)
    }

    /// Sends `initialize` from a client on `clientEnd`, then closes the wire
    /// and waits for the teardown of the agent.
    ///
    /// - Parameters:
    ///   - clientEnd: The client end of the wire.
    ///   - agentEnd: The agent end of the wire.
    ///   - agentConnection: The connection that serves the agent on
    ///     `agentEnd`.
    ///   - composed: The composition that `agentConnection` serves.
    /// - Returns: The response to `initialize`.
    /// - Throws: Whatever the handshake throws.
    private static func initialize(
        over clientEnd: InMemoryTransport,
        closing agentEnd: InMemoryTransport,
        served agentConnection: AgentSideConnection,
        by composed: ComposedAgent
    ) async throws -> InitializeResponse {
        let model = await ConnectionModel()
        let connection = await model.connect(over: clientEnd)
        // Swift has no asynchronous `defer`, and the wire must come down on
        // the failing path as well, so the outcome is held here and given
        // back after the teardown.
        let outcome: Result<InitializeResponse, any Error>
        do {
            outcome = .success(
                try await connection.initialize(AgentClientHarness.makeInitializeRequest()))
        } catch {
            outcome = .failure(error)
        }
        await connection.close()
        await agentConnection.close()
        clientEnd.close()
        agentEnd.close()
        await composed.waitForConnectionTeardown()
        return try outcome.get()
    }

    /// A host gives the composed agent to `AgentSideConnection` through the
    /// sync factory closure, and a client on an in-memory transport gets an
    /// answer to `initialize`.
    @Test(.timeLimit(.minutes(1)))
    func theFactoryClosureServesTheComposedAgent() async throws {
        let composed = try await Self.composeStubAgent(label: "ComposedAgentTests-factory")
        let (clientEnd, agentEnd) = InMemoryTransport.pair()

        let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            composed.agent(boundTo: connection)
        }
        let response = try await Self.initialize(
            over: clientEnd, closing: agentEnd, served: agentConnection, by: composed)

        #expect(composed.modelSource == .stub)
        #expect(response.info == RoutedACPAgent.implementation)
    }

    /// `serve(over:logger:)` binds the composed agent to a transport, and a
    /// client on the other end gets an answer to `initialize`.
    @Test(.timeLimit(.minutes(1)))
    func serveBindsTheComposedAgentToATransport() async throws {
        let composed = try await Self.composeStubAgent(label: "ComposedAgentTests-serve")
        let (clientEnd, agentEnd) = InMemoryTransport.pair()

        let agentConnection = await composed.serve(over: agentEnd)
        let response = try await Self.initialize(
            over: clientEnd, closing: agentEnd, served: agentConnection, by: composed)

        #expect(response.info == RoutedACPAgent.implementation)
    }
}

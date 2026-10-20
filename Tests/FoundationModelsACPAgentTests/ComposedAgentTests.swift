import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsSkills
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

    /// The branch of the git work tree of the snapshot proof.
    private static let branchName = "main"

    /// The prompt of the snapshot proof. The stub model echoes it.
    private static let promptText = "one turn in a git work tree"

    /// The name of the folder of the snapshots, under a hook data directory.
    private static let snapshotFolderName = "snapshot"

    /// The name of the folder of the hook data, under the data folder of the
    /// dotfolder name in the data home.
    private static let hooksFolderName = "hooks"

    /// The name of the folder of the transcripts, under the project
    /// dotfolder.
    private static let transcriptsFolderName = "transcripts"

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
        try await exchange(over: clientEnd, closing: agentEnd, served: agentConnection, by: composed) {
            try await $0.initialize(AgentClientHarness.makeInitializeRequest())
        }
    }

    /// Runs `requests` from a client on `clientEnd`, then closes the wire and
    /// waits for the teardown of the agent.
    ///
    /// - Parameters:
    ///   - clientEnd: The client end of the wire.
    ///   - agentEnd: The agent end of the wire.
    ///   - agentConnection: The connection that serves the agent on
    ///     `agentEnd`.
    ///   - composed: The composition that `agentConnection` serves.
    ///   - requests: The requests that the client sends over its connection.
    /// - Returns: The value that `requests` gives.
    /// - Throws: Whatever `requests` throws.
    private static func exchange<Value: Sendable>(
        over clientEnd: InMemoryTransport,
        closing agentEnd: InMemoryTransport,
        served agentConnection: AgentSideConnection,
        by composed: ComposedAgent,
        _ requests: (ClientSideConnection) async throws -> Value
    ) async throws -> Value {
        let model = await ConnectionModel()
        let connection = await model.connect(over: clientEnd)
        // Swift has no asynchronous `defer`, and the wire must come down on
        // the failing path as well, so the outcome is held here and given
        // back after the teardown.
        let outcome: Result<Value, any Error>
        do {
            outcome = .success(try await requests(connection))
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

    /// Sends `initialize`, `session/new` in `workspace` and one prompt from a
    /// client of `composed`, then closes the wire and waits for the teardown
    /// of the agent.
    ///
    /// - Parameters:
    ///   - composed: The composition that serves the client.
    ///   - workspace: The working directory of the session.
    /// - Returns: The id of the session.
    /// - Throws: Whatever the handshake, the session call or the prompt
    ///   throws.
    private static func runOneTurn(of composed: ComposedAgent, in workspace: URL) async throws -> SessionId {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await composed.serve(over: agentEnd)
        return try await exchange(over: clientEnd, closing: agentEnd, served: agentConnection, by: composed) {
            connection in
            _ = try await connection.initialize(AgentClientHarness.makeInitializeRequest())
            let session = try await connection.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
            // Subscribe before the prompt, so the stream holds the idle
            // update of the prompt. The wire stays open until that update
            // came, thus no update of the turn fails to go out.
            let updates = connection.subscribe(to: session.sessionId).updates
            _ = try await connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: session.sessionId, text: promptText))
            for await case .update(.stateUpdate(.idle)) in updates {
                break
            }
            return session.sessionId
        }
    }

    /// A host gives the composed agent to `AgentSideConnection` through the
    /// sync factory closure, and a client on an in-memory transport gets an
    /// answer to `initialize`.
    @Test
    func theFactoryClosureServesTheComposedAgent() async throws {
        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "ComposedAgentTests-factory")
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
    @Test
    func serveBindsTheComposedAgentToATransport() async throws {
        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "ComposedAgentTests-serve")
        let (clientEnd, agentEnd) = InMemoryTransport.pair()

        let agentConnection = await composed.serve(over: agentEnd)
        let response = try await Self.initialize(
            over: clientEnd, closing: agentEnd, served: agentConnection, by: composed)

        #expect(response.info == RoutedACPAgent.implementation)
    }

    /// A host that gives `hooksDataDirectory` gets the snapshot timeline in
    /// its `snapshot` folder: one turn in a git work tree writes its
    /// transcript file, and the shadow folder of the session key (the ACP
    /// session id) is under `<hooksDataDirectory>/snapshot`. The data home
    /// gets no hook data.
    @Test
    func theSnapshotsOfAGivenHooksDataDirectoryAreInItsSnapshotFolder() async throws {
        let workspace = makeResolvedDirectory(label: "ComposedAgentTests-snapshot-repo")
        try GitVerbSupport.makeRepository(in: workspace, branch: Self.branchName)
        let hooksDataDirectory = makeResolvedDirectory(label: "ComposedAgentTests-snapshot-hooks")
        let dataHome = makeResolvedDirectory(label: "ComposedAgentTests-snapshot-data")
        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "ComposedAgentTests-snapshot", workspace: workspace,
            hooksDataDirectory: hooksDataDirectory, dataHome: dataHome)

        let sessionId = try await Self.runOneTurn(of: composed, in: workspace)

        let transcripts = workspace.appendingPathComponent(".\(Self.dotfolderName)", isDirectory: true)
            .appendingPathComponent(Self.transcriptsFolderName, isDirectory: true)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: transcripts.path)).isEmpty)
        let shadow = hooksDataDirectory.appendingPathComponent(Self.snapshotFolderName, isDirectory: true)
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
        #expect(Self.isDirectory(shadow))
        let defaultHooks = dataHome.appendingPathComponent(Self.dotfolderName, isDirectory: true)
            .appendingPathComponent(Self.hooksFolderName, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: defaultHooks.path))
    }

    /// A host that gives `skillsMarketplaceCacheDirectory` gets the skills
    /// marketplace cache in that folder, also when `SKILLS_MARKETPLACE_CACHE`
    /// of the environment names an other folder: one turn in a workspace
    /// whose project layer names a local marketplace fills the folder of the
    /// host, and the folder of the environment stays empty.
    @Test
    func theSkillsMarketplaceCacheOfAGivenFolderWinsOverTheEnvironment() async throws {
        let repository = try SkillsMarketplaceTests.makeMarketplaceRepository()
        let workspace = makeResolvedDirectory(label: "ComposedAgentTests-marketplace-repo")
        try ConfigFileFixture.write(
            SkillsMarketplaceTests.marketplaceConfiguration(repository: repository),
            in: workspace.appendingPathComponent(".\(Self.dotfolderName)", isDirectory: true))
        let hostCache = makeResolvedDirectory(label: "ComposedAgentTests-marketplace-host-cache")
        let environmentCache = makeResolvedDirectory(label: "ComposedAgentTests-marketplace-environment-cache")
        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "ComposedAgentTests-marketplace", workspace: workspace,
            skillsMarketplaceCacheDirectory: hostCache,
            environment: [MarketplaceStore.cacheDirectoryVariable: environmentCache.path])

        _ = try await Self.runOneTurn(of: composed, in: workspace)

        #expect(!(try FileManager.default.contentsOfDirectory(atPath: hostCache.path)).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: environmentCache.path).isEmpty)
    }

    /// Tells if a directory is at `url`.
    ///
    /// - Parameter url: The location to examine.
    /// - Returns: `true` when a directory is at `url`, and `false` when
    ///   nothing or a file is at `url`.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

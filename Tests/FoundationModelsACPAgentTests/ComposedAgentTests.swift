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

    /// The name of the folder of the transcripts, under the project
    /// dotfolder.
    private static let transcriptsFolderName = "transcripts"

    /// The `compaction.trigger` that the `config.yaml` of the synced root
    /// sets.
    private static let syncedRootTrigger = 0.7

    /// The `config.yaml` of the synced root of a home.
    private static let syncedRootConfiguration = "compaction:\n  trigger: \(syncedRootTrigger)\n"

    /// The name of a project folder in the synced root of a home.
    private static let projectFolderName = "project"

    /// The name of the shell store folder in the project state folder.
    private static let shellStoreFolderName = "shell"

    /// The variables of the user home, each with its folder relative to the
    /// user home: `HOME` itself and the XDG base folders.
    private static let userHomeVariables = [
        ("HOME", ""), ("XDG_CONFIG_HOME", ".config"), ("XDG_DATA_HOME", ".local/share"),
        ("XDG_CACHE_HOME", ".cache"), ("XDG_STATE_HOME", ".local/state"),
    ]

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
        await composed.closeOpenSessions()
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

    /// A host home gives the user layer of the settings: the `config.yaml`
    /// of the synced root sets the configuration of the composition.
    @Test
    func theSyncedRootOfTheHomeIsTheUserLayerOfTheSettings() async throws {
        let home = AgentHomeFixture.make(label: "ComposedAgentTests-settings")
        try ConfigFileFixture.write(Self.syncedRootConfiguration, in: home.synced)

        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "ComposedAgentTests-settings", home: home)

        #expect(composed.configuration.compaction.trigger == Self.syncedRootTrigger)
    }

    /// A host home gets the snapshot timeline in the `snapshot` folder of its
    /// hooks folder: one prompt in a git work tree writes its transcript file,
    /// and the shadow folder of the session key (the ACP session id) is under
    /// `<local>/hooks/snapshot`.
    @Test
    func theSnapshotsOfAHomeAreInItsHooksFolder() async throws {
        let workspace = makeResolvedDirectory(label: "ComposedAgentTests-snapshot-repo")
        try GitVerbSupport.makeRepository(in: workspace, branch: Self.branchName)
        let home = AgentHomeFixture.make(label: "ComposedAgentTests-snapshot")
        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "ComposedAgentTests-snapshot", workspace: workspace, home: home)

        let sessionId = try await Self.runOneTurn(of: composed, in: workspace)

        let transcripts = workspace.appendingPathComponent(".\(Self.dotfolderName)", isDirectory: true)
            .appendingPathComponent(Self.transcriptsFolderName, isDirectory: true)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: transcripts.path)).isEmpty)
        let shadow = home.hooksDirectory.appendingPathComponent(Self.snapshotFolderName, isDirectory: true)
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
        #expect(Self.isDirectory(shadow))
    }

    /// A host home gets the skills marketplace cache in its local root, also
    /// when `SKILLS_MARKETPLACE_CACHE` of the environment names an other
    /// folder: one prompt in a workspace whose project layer names a local
    /// marketplace fills the folder of the home, and the folder of the
    /// environment stays empty.
    @Test
    func theSkillsMarketplaceCacheOfAHomeWinsOverTheEnvironment() async throws {
        let repository = try SkillsMarketplaceTests.makeMarketplaceRepository()
        let workspace = makeResolvedDirectory(label: "ComposedAgentTests-marketplace-repo")
        try ConfigFileFixture.write(
            SkillsMarketplaceTests.marketplaceConfiguration(repository: repository),
            in: workspace.appendingPathComponent(".\(Self.dotfolderName)", isDirectory: true))
        let home = AgentHomeFixture.make(label: "ComposedAgentTests-marketplace")
        let environmentCache = makeResolvedDirectory(label: "ComposedAgentTests-marketplace-environment-cache")
        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "ComposedAgentTests-marketplace", workspace: workspace, home: home,
            environment: [MarketplaceStore.cacheDirectoryVariable: environmentCache.path])

        _ = try await Self.runOneTurn(of: composed, in: workspace)

        #expect(
            !(try FileManager.default.contentsOfDirectory(atPath: home.skillsMarketplaceCacheDirectory.path)).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: environmentCache.path).isEmpty)
    }

    /// The isolation of a host home (task ^98a44n7): with a custom home, and
    /// with `HOME` and the XDG variables of the environment in an other empty
    /// folder, a composed session and one prompt write nothing in that other
    /// folder. Each stack reads its user layer from the home.
    @Test
    func aCustomHomeKeepsTheSessionOutOfTheUserHome() async throws {
        let workspace = makeResolvedDirectory(label: "ComposedAgentTests-isolation-repo")
        try GitVerbSupport.makeRepository(in: workspace, branch: Self.branchName)
        let userHome = makeResolvedDirectory(label: "ComposedAgentTests-isolation-user-home")
        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "ComposedAgentTests-isolation", workspace: workspace,
            home: AgentHomeFixture.make(label: "ComposedAgentTests-isolation"),
            environment: Self.environment(pointingAt: userHome))

        _ = try await Self.runOneTurn(of: composed, in: workspace)

        #expect(try FileManager.default.contentsOfDirectory(atPath: userHome.path).isEmpty)
    }

    /// A project folder can be in the synced root of the home (the Mac app
    /// keeps its projects there), thus the machine state of a session never
    /// goes into its working directory: the shell store is in the project
    /// state folder of the local root, and the working directory gets no
    /// `.shell` folder.
    @Test
    func aSessionInTheSyncedRootKeepsItsShellStoreInTheLocalRoot() async throws {
        let home = AgentHomeFixture.make(label: "ComposedAgentTests-synced-project")
        let workspace = home.synced.appendingPathComponent(Self.projectFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "ComposedAgentTests-synced-project", workspace: workspace, home: home)

        _ = try await Self.runOneTurn(of: composed, in: workspace)

        let shellStore = home.projectStateDirectory(of: workspace)
            .appendingPathComponent(Self.shellStoreFolderName, isDirectory: true)
        #expect(Self.isDirectory(shellStore))
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".shell").path))
    }

    /// An environment whose `HOME` and XDG base folders are all in `folder`.
    ///
    /// - Parameter folder: The folder of the user home.
    /// - Returns: The environment.
    private static func environment(pointingAt folder: URL) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: userHomeVariables.map { variable, path in
                (variable, folder.appendingPathComponent(path, isDirectory: true).path)
            })
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

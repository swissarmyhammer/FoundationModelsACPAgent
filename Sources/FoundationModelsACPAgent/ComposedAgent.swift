import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// The composed agent of a host: the configuration stack of a dotfolder
/// name, a router over a model path, and the `RoutedACPAgent` that
/// resolves the profile (cli-plan.md §5.10, plan.md §20.2).
///
/// The work has two steps, and only the first one is slow or can fail:
///
/// 1. ``compose(name:workingDirectory:environment:modelSource:stubChunkDelay:reporting:)``
///    loads the configuration, builds the router and resolves the profile.
///    It is `async` and `throws`. A host calls it one time, before it opens
///    a connection.
/// 2. ``agent(boundTo:)`` binds the composed agent to one
///    `AgentSideConnection` and gives it back as `any Agent`. It is
///    synchronous and does not throw, so the factory closure of
///    `AgentSideConnection` calls it directly. It starts no transport and
///    no serve loop of its own.
///
/// A host that runs the agent in its own process writes:
///
/// ```swift
/// let composed = try await ComposedAgent.compose(
///     name: try DotfolderName("my-host"), workingDirectory: projectDirectory)
/// let connection = await AgentSideConnection(stream: transport) { connection in
///     composed.agent(boundTo: connection)
/// }
/// ```
///
/// ``serve(over:logger:)`` does the same two lines in one call. The
/// `acp-agent` executable uses it for its stdio and in-process modes.
///
/// After the connection closed, and before the process ends, the host
/// calls ``waitForConnectionTeardown()``, so the agent can close each
/// open session.
///
/// Where a frontend appends its own tools (plan.md §11.1): `ToolCatalog`
/// is the one place this package composes the per-session tool surface.
/// A capability behind the code-mode surface is one
/// `builder.withCapability(myCapability)` call in
/// `ToolCatalog.makeRegistry(context:)`; a stand-alone tool is one plain
/// `FoundationModels.Tool` appended in `ToolCatalog.sessionSurface(context:)`,
/// the way the `skills` tool is.
public struct ComposedAgent: Sendable {
    /// Which model path the router resolves the profile through.
    public enum ModelSource: Equatable, Sendable {
        /// `LiveModelLoader`, which loads each model through the Extras
        /// `MLXModelLoader`: the configured models download on first use
        /// and load as resident weights. Nothing here is scripted or
        /// stubbed.
        case live

        /// The library's deterministic `EchoModel` path: every session
        /// answers a prompt with the prompt itself, no metadata is
        /// fetched, no weights download, and nothing loads.
        case stub
    }

    /// The prefix of the throwaway cache directory a stub router writes
    /// its stub metadata under. The real caches directory must never hold
    /// that metadata: it names real model ids, and a later live run would
    /// read the fake sizes back.
    private static let stubCacheDirectoryPrefix = "acp-agent-stub-cache-"

    /// The prefix of the throwaway directory the router's own recordings
    /// root stands at — see ``makeRecordingsDirectory()``.
    private static let recordingsDirectoryPrefix = "acp-agent-recordings-"

    /// The composed agent, with its profile resolved.
    public let agent: RoutedACPAgent

    /// The model path ``agent`` resolves through.
    public let modelSource: ModelSource

    /// The configuration of the start-up load — the first of the two
    /// loads of cli-plan.md §5.10, keyed by the directory this
    /// composition was built for. Each session later loads its own
    /// stack again, keyed by the session's `cwd`.
    public let configuration: AgentConfiguration

    /// Composes the agent: the configuration of `workingDirectory`'s
    /// stack under `name`, a router over `modelSource`, and the
    /// `RoutedACPAgent` construction that resolves the profile.
    ///
    /// The layered `config.yaml` of `workingDirectory` selects the profile
    /// the agent resolves at start (plan.md §2.2). With no file in any
    /// layer the in-code default applies. Each session later loads its own
    /// stack again, keyed by the session's `cwd`.
    ///
    /// Call this one time, before the first connection. Then give each
    /// connection the agent with ``agent(boundTo:)``.
    ///
    /// - Parameters:
    ///   - name: The dotfolder name the host chose (plan.md §2.1). It
    ///     roots the configuration stack and the transcript directory.
    ///   - workingDirectory: The directory whose dotfolder stack the
    ///     start-up configuration loads from.
    ///   - environment: The environment the stack reads `XDG_CONFIG_HOME`
    ///     from. The process environment by default.
    ///   - modelSource: The model path to build the router over.
    ///     ``ModelSource/live`` by default.
    ///   - stubChunkDelay: The pause a stub answer puts between two
    ///     chunks, or `nil` (the default) for the one-chunk echo. Only
    ///     ``ModelSource/stub`` reads it.
    ///   - progress: The progress object the resolution reports into, or
    ///     `nil` for a fresh unobserved one. A caller that draws a
    ///     download bar makes the object first, hands it here, and
    ///     observes the same object while this call runs: the whole
    ///     resolution stands inside the agent's construction, so nothing
    ///     can be observed after this returns.
    /// - Returns: The composed agent, the model path it was built over, and
    ///   the configuration the load resolved.
    /// - Throws: The configuration load errors, the creation error of a
    ///   throwaway directory of the router, or `ProfileResolutionError`
    ///   when the profile does not resolve. Each is fatal before the wire
    ///   opens.
    public static func compose(
        name: DotfolderName,
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        modelSource: ModelSource = .live,
        stubChunkDelay: Swift.Duration? = nil,
        reporting progress: ResolutionProgress? = nil
    ) async throws -> ComposedAgent {
        let configuration = try ConfigurationLoader(
            name: name, workingDirectory: workingDirectory, environment: environment
        ).load().configuration
        let agent = try await RoutedACPAgent(
            name: name,
            router: try makeRouter(
                for: modelSource,
                pacedBy: stubChunkDelay,
                recordingInto: try makeRecordingsDirectory()),
            configuration: configuration,
            reporting: progress,
            environment: environment)
        return ComposedAgent(
            agent: agent, modelSource: modelSource, configuration: configuration)
    }

    /// Binds ``agent`` to `connection`, so a prompt can notify through it
    /// (plan.md §8.1), and gives the agent back.
    ///
    /// Call it from the factory closure of `AgentSideConnection`. It is
    /// synchronous and does not throw. It starts no transport and no serve
    /// loop: the connection that called it serves the agent.
    ///
    /// - Parameter connection: The connection around the agent.
    /// - Returns: ``agent``, bound to `connection`.
    public func agent(boundTo connection: AgentSideConnection) -> any Agent {
        agent.bind(connection: connection)
        return agent
    }

    /// Binds ``agent`` to the agent side of `transport`, so a client
    /// on the other end drives it over ACP.
    ///
    /// The `acp-agent` executable hands the agent to a connection here
    /// alone. `run` gives one end of `InMemoryTransport.pair()`, and `acp`
    /// gives stdin and stdout; nothing else about the two modes differs
    /// (cli-plan.md §4).
    ///
    /// - Parameters:
    ///   - transport: The wire end the agent serves on.
    ///   - logger: The diagnostic sink of the connection. It writes
    ///     to stderr or nowhere, never to stdout (§5.6).
    /// - Returns: The bound connection.
    public func serve(
        over transport: any ACPTransport, logger: ACPLogger = .disabled
    ) async -> AgentSideConnection {
        await AgentSideConnection(stream: transport, logger: logger) { connection in
            agent(boundTo: connection)
        }
    }

    /// Waits until ``agent`` closed its open sessions after the close of
    /// the latest connection that ``agent(boundTo:)`` bound.
    ///
    /// A host does not have to send `session/close`: the client closes
    /// the wire, and the agent closes each open session itself
    /// (plan.md §10.1). A host calls this after the connection closed
    /// and before the process exits, so the agent can write the history
    /// of each session and stop its MCP servers.
    public func waitForConnectionTeardown() async {
        await agent.waitForConnectionTeardown()
    }

    /// Makes the router of one model path.
    ///
    /// Both paths take the recordings directory, because that directory is
    /// what sets the recorder on: a router built without one holds the
    /// no-op sink, and every event of every session drops (plan.md §4.1).
    /// Each session then names its own root, and Router records the
    /// session to `<root>/<sessionId>/`.
    ///
    /// The live loader takes no progress callback. The callback of its
    /// init receives only the loads of the Extras model pool. A router load
    /// gives its download bytes to the `ResolutionProgress` of the resolve,
    /// and the download bar of cli-plan.md §5.7 observes that object.
    ///
    /// - Parameters:
    ///   - modelSource: The model path to build the router over.
    ///   - chunkDelay: The pause a stub answer puts between two chunks,
    ///     or `nil` for the library's one-chunk echo. The live path
    ///     ignores it.
    ///   - recordingsDirectory: The router's own recordings root — see
    ///     ``makeRecordingsDirectory()``.
    /// - Returns: A router over `LiveModelLoader` for ``ModelSource/live``,
    ///   or the library's `EchoModel` router — stub machine, stub
    ///   metadata, echo loader — for ``ModelSource/stub``.
    /// - Throws: The directory-creation error of the stub cache.
    private static func makeRouter(
        for modelSource: ModelSource,
        pacedBy chunkDelay: Swift.Duration?,
        recordingInto recordingsDirectory: URL
    ) throws -> Router {
        switch modelSource {
        case .live:
            Router(recordingsDir: recordingsDirectory, loader: LiveModelLoader())
        case .stub:
            EchoModel.makeRouter(
                cacheDirectory: try makeStubCacheDirectory(),
                recordingsDirectory: recordingsDirectory,
                loader: makeStubLoader(pacedBy: chunkDelay))
        }
    }

    /// Makes the loader of the stub path.
    ///
    /// - Parameter chunkDelay: The pause between two chunks, or `nil`.
    /// - Returns: The library's own stub loader when `chunkDelay` is
    ///   `nil`, and one over ``PacedEchoLLMContainer`` otherwise.
    private static func makeStubLoader(pacedBy chunkDelay: Swift.Duration?) -> StubModelLoader {
        guard let chunkDelay else {
            return StubModelLoader()
        }
        return StubModelLoader { _ in PacedEchoLLMContainer(pause: chunkDelay) }
    }

    /// Makes a fresh throwaway directory for a stub router's cache — see
    /// ``stubCacheDirectoryPrefix``.
    ///
    /// - Returns: The created directory, under the temporary directory.
    /// - Throws: The directory-creation error.
    private static func makeStubCacheDirectory() throws -> URL {
        try makeThrowawayDirectory(prefix: stubCacheDirectoryPrefix)
    }

    /// Makes the router's own recordings root: a fresh throwaway
    /// directory, one for each composition.
    ///
    /// The router root is the switch, and not a destination. Router writes
    /// each session to the root that session was given — the project's
    /// `transcripts.location` — so nothing a user reads is written here.
    /// Three facts make a throwaway directory the correct switch:
    ///
    /// - `JSONLRecorder` locks its own root. Two agent processes in one
    ///   project would then contend for one lock, and the process that
    ///   loses records nothing. A root per process cannot contend.
    /// - A session that names no root of its own records under the router
    ///   root. The librarian sessions of the tool catalog are such
    ///   sessions, and a project root would mix them into the project's
    ///   own transcripts.
    /// - An `acp` server opens sessions in directories other than the one
    ///   it started in, so its start-up directory must not become a
    ///   recording root.
    ///
    /// - Returns: The created directory, under the temporary directory.
    /// - Throws: The directory-creation error.
    private static func makeRecordingsDirectory() throws -> URL {
        try makeThrowawayDirectory(prefix: recordingsDirectoryPrefix)
    }

    /// Makes a fresh directory under the temporary directory, named
    /// `prefix` and a new UUID.
    ///
    /// - Parameter prefix: The name prefix, which says what the directory
    ///   is for.
    /// - Returns: The created directory.
    /// - Throws: The directory-creation error.
    private static func makeThrowawayDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

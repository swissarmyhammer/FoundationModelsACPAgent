import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter

/// Whether a session can accept a new prompt (plan.md §7.1). `idle` means
/// "ready for a new prompt"; a `session/prompt` that arrives while the
/// session is `busy` is a client error, not a queue entry — the composer
/// owns queueing, and Router's own prompt queue is never shown over ACP.
enum SessionAvailability: Equatable, Sendable {
    /// The session is ready for a new prompt.
    case idle

    /// A prompt turn is in flight.
    // The prompt-turn task is what moves a session here; until it lands,
    // every session stays idle.
    // periphery:ignore
    case busy
}

/// One live session in the agent's table (plan.md §7.1): the root Router
/// session plus everything the session composed per cwd — its config, its
/// assembled instructions, its confinement root set, its transcript
/// directory, and the mounted tool surface whose pool the session
/// lifecycle shuts down at close.
struct ActiveSession: Sendable {
    /// The root Router session. Retaining it is what keeps the resident
    /// profile alive for this session's lifetime.
    let session: any RoutedSession

    /// The merged per-cwd configuration this session was composed from
    /// (plan.md §2.2).
    let configuration: AgentConfiguration

    /// The assembled instructions text the session was born with
    /// (plan.md §3). A running session keeps this text through each
    /// compaction fold; only a new session re-assembles.
    let instructions: String

    /// The session working directory — the base for relative paths and
    /// the root set's first member (plan.md §7.2).
    let workingDirectory: URL

    /// The session's additional confinement roots, in wire order
    /// (plan.md §7.2). They extend confinement only; they never change
    /// ``workingDirectory``.
    let additionalRoots: [URL]

    /// The session's own transcript directory,
    /// `<recording root>/<sessionId>/` (plan.md §4.1).
    let transcriptDirectory: URL

    /// The mounted tool surface. The session-close task calls
    /// `surface.serverPool.shutdownAll()` after the session sweep
    /// (plan.md §11.5).
    let surface: SessionSurface

    /// Whether the session is ready for a new prompt.
    var availability: SessionAvailability
}

/// The per-session composition helpers of `session/new` (plan.md §7.1):
/// cwd validation and the config → instructions → tools pipeline that
/// feeds `profile.standard.makeSession(...)`.
enum SessionSetup {
    /// The prefix every absolute path starts with.
    private static let absolutePathPrefix = "/"

    /// Validates that `path` is absolute and returns it as a directory
    /// URL. `cwd` MUST be absolute (plan.md §7.1): it keys the config
    /// layer, the AGENTS.md walk, and the transcript directory, and a
    /// relative path would key them off the process cwd instead.
    ///
    /// - Parameter path: The `cwd` string of the request.
    /// - Returns: The working directory URL.
    /// - Throws: `RequestError.invalidParams` when `path` is relative —
    ///   the same JSON-RPC error the wire decode of `AbsolutePath` gives.
    static func validatedWorkingDirectory(path: String) throws(RequestError) -> URL {
        guard path.hasPrefix(absolutePathPrefix) else {
            throw .invalidParams
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The user layer's root in `stack`, `~/.config/<name>/` in
    /// production. `ProjectRegistry` lives there (plan.md §4.5), and the
    /// `home` transcript location resolves against it (§4.1).
    ///
    /// - Parameter stack: The session's dotfolder stack.
    /// - Returns: The user layer root.
    static func userLayerRoot(of stack: DotfolderStack) -> URL {
        guard let userLayer = stack.layers.first(where: { $0.source == .user }) else {
            preconditionFailure("DotfolderStack always builds a user layer")
        }
        return userLayer.root
    }
}

/// What one `session/new` composed before the session was made
/// (plan.md §7.1): the merged config, the assembled instructions, the
/// mounted tool surface, and the resolved recording root.
struct SessionComposition {
    /// The merged per-cwd configuration (plan.md §2.2).
    let configuration: AgentConfiguration

    /// The assembled instructions text (plan.md §3).
    let instructions: String

    /// The mounted tool surface (plan.md §11.1).
    let surface: SessionSurface

    /// The user layer root the stack resolved, for the project registry
    /// and the `home` transcript location.
    let userLayerRoot: URL

    /// The recording root `makeSession(recordingRoot:)` receives; Router
    /// records the session to `<transcriptRoot>/<sessionId>/` (plan.md §4.1).
    let transcriptRoot: URL
}

extension RoutedACPAgent {
    /// Creates one root Router session for `params.cwd` (plan.md §7.1).
    ///
    /// The ACP `sessionId` IS the root Router session's ULID, serialized —
    /// there is no mapping table (§4.2). The cwd is registered in the
    /// project registry now; the `sessions.jsonl` index record waits for
    /// the first recorded activity, because §9's zero-turn rule makes a
    /// persisted transcript the listability test.
    ///
    /// - Parameter params: The request: the absolute `cwd`, the ordered
    ///   `additionalDirectories`, and the client's session-scoped
    ///   `mcpServers` (§7.2, §7.3).
    /// - Returns: The response carrying the new sessionId and the
    ///   `configOptions` list.
    /// - Throws: The order rule's invalid-request error,
    ///   `RequestError.invalidParams` for a relative cwd, or whatever the
    ///   composition pipeline throws.
    public func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        try requireInitialized(before: ACPMethod.sessionNew)
        let workingDirectory = try SessionSetup.validatedWorkingDirectory(
            path: params.cwd.rawValue)
        let additionalRoots = (params.additionalDirectories ?? []).map { path in
            URL(fileURLWithPath: path.rawValue, isDirectory: true)
        }

        let composition = try await composeSession(
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            clientMCPServers: params.mcpServers ?? [])

        // The session comes from the profile's standard slot, never from
        // the router (plan.md §7.1). `grammar` stays absent — a plain
        // session, not a guided one — and `agentSpawn` stays nil: agents
        // arrive later as a Multitool code-mode background capability
        // (§11.3), spawned from inside a tool call, never from
        // `session/new`.
        // TODO(^f40jzjy): derive the TokenBudget from the `compaction:`
        // section once Router publicly shows the resolved context;
        // `SlotResolution.contextTokens` is package-internal today, so
        // automatic compaction stays off.
        let session = residentProfile.standard.makeSession(
            instructions: composition.instructions,
            workingDirectory: workingDirectory,
            recordingRoot: composition.transcriptRoot,
            tools: composition.surface.tools,
            budget: nil,
            compactionPrompt: .default)

        // Register the cwd now (plan.md §4.5). The `sessions.jsonl` index
        // record is NOT written here: the prompt-turn task appends it at
        // the first recorded activity, with the title (§9).
        try ProjectRegistry(directory: composition.userLayerRoot)
            .recordSessionStart(workingDirectory: workingDirectory)

        let sessionId = SessionId(rawValue: session.id.description)
        sessions[sessionId] = ActiveSession(
            session: session,
            configuration: composition.configuration,
            instructions: composition.instructions,
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            transcriptDirectory: session.recordingDirectory,
            surface: composition.surface,
            availability: .idle)

        // TODO(^r7t7xe1): the config-options task fills `configOptions`
        // with the model slot selector; until then the list is honestly
        // empty.
        return NewSessionResponse(sessionId: sessionId, configOptions: [])
    }

    /// Runs the per-session composition pipeline (plan.md §7.1): resolve
    /// the cwd config layer, assemble the instructions, then connect the
    /// MCP servers and build the tool roster through the catalog.
    ///
    /// - Parameters:
    ///   - workingDirectory: The validated session working directory.
    ///   - additionalRoots: The session's additional confinement roots,
    ///     in wire order.
    ///   - clientMCPServers: The client's session-scoped MCP servers, in
    ///     wire order (§7.3).
    /// - Returns: The composed inputs of `makeSession`.
    /// - Throws: Whatever the config load, the instructions assembly, or
    ///   the tool composition throws.
    private func composeSession(
        workingDirectory: URL,
        additionalRoots: [URL],
        clientMCPServers: [FoundationModelsACP.MCPServer]
    ) async throws -> SessionComposition {
        let loader = ConfigurationLoader(
            name: name,
            workingDirectory: workingDirectory,
            userDirectory: userDirectory,
            environment: environment)
        let loaded = try loader.load()

        let context = CatalogContext(
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            configuration: loaded.configuration,
            profile: residentProfile,
            clientMCPServers: clientMCPServers)

        let instructions = try InstructionsAssembler(
            stack: loader.stack, workingDirectory: workingDirectory
        ).assemble(skills: ToolCatalog.makeSkillsRegistry(context: context))

        let surface = try await ToolCatalog.sessionSurface(context: context)

        let userLayerRoot = SessionSetup.userLayerRoot(of: loader.stack)
        return SessionComposition(
            configuration: loaded.configuration,
            instructions: instructions.text,
            surface: surface,
            userLayerRoot: userLayerRoot,
            transcriptRoot: loaded.configuration.transcripts.location.recordingRoot(
                workingDirectory: workingDirectory,
                name: name,
                userDirectory: userLayerRoot))
    }
}

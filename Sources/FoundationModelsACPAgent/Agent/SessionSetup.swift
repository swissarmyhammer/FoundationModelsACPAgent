import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import FoundationModelsSkills
import os

/// The logger of the session composition surface: the confinement-root
/// conversion's skip reports.
private let setupLogger = Logger(
    subsystem: RoutedACPAgent.implementation.name, category: "SessionSetup")

/// Whether a session can accept a new prompt (plan.md §7.1). `idle` means
/// "ready for a new prompt"; a `session/prompt` that arrives while the
/// session is `busy` is a client error, not a queue entry — the composer
/// owns queueing, and Router's own prompt queue is never shown over ACP.
/// A `closed` session is resumable, not promptable (plan.md §10.1).
enum SessionAvailability: Equatable, Sendable {
    /// The session is ready for a new prompt.
    case idle

    /// A prompt turn is in flight.
    case busy

    /// `session/close` released the session. The transcript stays, so
    /// `session/resume` can bring it back.
    case closed
}

/// One live session in the agent's table (plan.md §7.1): the root Router
/// session plus everything the session composed per cwd — its config, its
/// assembled instructions, its confinement root set, its transcript
/// directory, and the mounted tool surface whose pool the session
/// lifecycle shuts down at close.
struct ActiveSession: Sendable {
    /// The Router session that answers this ACP session's turns.
    /// Retaining it is what keeps the resident profile alive for this
    /// session's lifetime. Born as the root session from the standard
    /// slot; a model-slot switch (plan.md §15) replaces it with one
    /// vended from the selected slot's handle.
    var session: any RoutedSession

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

    /// The session's slash-command registry (plan.md §14.1), assembled
    /// at session creation. The `prompt()` handler dispatches a leading
    /// `/name` through it before anything touches the session (§14.3).
    let commands: CommandRegistry

    /// The model slot ``session`` was vended from (plan.md §15). Only
    /// `standard` and `flash` occur; embedding is not a chat slot.
    var selectedSlot: ModelSlot

    /// The config-option state the client last saw (plan.md §15):
    /// what `session/new` or `session/set_config_option` answered, or a
    /// `config_option_update` pushed. The divergence check compares the
    /// truth against this baseline.
    var announcedConfigOptions: [SessionConfigOption]

    /// The running turn's state owner, or `nil` when no turn is in
    /// flight (plan.md §8.2). `session/cancel` reaches the turn through
    /// this reference.
    var activeTurn: TurnStateOwner?

    /// The session's descendants — its forks and, later, its spawned
    /// sub-agents (plan.md §10.1). `session/close` closes each one, so no
    /// orphan holds a model gate after the parent goes. This iteration holds
    /// forks; the path stays open for the spawned sessions a later Multitool
    /// agents capability starts.
    var descendants: [any RoutedSession] = []

    /// Whether `session/close` released this session (plan.md §10.1).
    var isClosed = false

    /// Whether the `sessions.jsonl` record was written. The first prompt
    /// writes it, deferred from `session/new` by §9's zero-turn rule.
    var indexRecorded = false

    /// Whether the session can accept a new prompt. Derived, so the
    /// stored turn reference stays the one source of the busy state.
    var availability: SessionAvailability {
        if isClosed {
            return .closed
        }
        return activeTurn == nil ? .idle : .busy
    }
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

    /// Converts the wire `additionalDirectories` path strings to
    /// confinement root URLs, in wire order (plan.md §7.2).
    ///
    /// A non-absolute entry is skipped with a log and never refuses the
    /// session: the wire decode already drops one silently
    /// (`x-deserialize-skip-invalid-items`), and this guard keeps the
    /// same rule for every caller, so the confinement boundary does not
    /// rest on the care of the layer above.
    ///
    /// - Parameter paths: The requested directory paths, in wire order.
    /// - Returns: The confinement root URLs, in the same order.
    static func additionalRoots(fromPaths paths: [String]) -> [URL] {
        paths.compactMap { path in
            guard path.hasPrefix(absolutePathPrefix) else {
                setupLogger.warning(
                    "additionalDirectories entry \(path, privacy: .public) is not absolute; skipped"
                )
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
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

/// The per-cwd configuration resolution one session request starts from
/// (plan.md §2.2, §4.1): the loader whose stack the instructions assembly
/// reads, the merged configuration, the user layer root, and the resolved
/// recording root.
///
/// `session/new` resolves and composes in one motion; `session/resume`
/// resolves first, runs the cwd pre-check against ``transcriptRoot``, and
/// composes only after the check passes (plan.md §7.4).
struct LoadedSessionContext {
    /// The loader whose dotfolder stack the instructions assembly reads.
    let loader: ConfigurationLoader

    /// The merged and decoded configuration.
    let loaded: LoadedConfiguration

    /// The user layer root the stack resolved.
    let userLayerRoot: URL

    /// The resolved recording root (plan.md §4.1).
    let transcriptRoot: URL
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

    /// The later slash-command sources (plan.md §14.1), in precedence order:
    /// the catalog's linked conformers, then the registered providers, then
    /// the skills source. The registry is assembled in `newSession`, once the
    /// live session the builtins capture exists.
    let commandProviders: [any SlashCommandProviding]

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
        let additionalRoots = SessionSetup.additionalRoots(
            fromPaths: (params.additionalDirectories ?? []).map(\.rawValue))

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

        // The `sessions.jsonl` index record is NOT written here: the
        // prompt-turn task appends it at the first recorded activity,
        // with the title (§9).
        let activation = try await activateSession(
            session,
            composition: composition,
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            indexRecorded: false)

        return NewSessionResponse(
            sessionId: activation.sessionId, configOptions: activation.configOptions)
    }

    /// Mounts one made or restored Router session into the agent (plan.md
    /// §7.1, §7.4): the project-registry record, the command registry with
    /// its bound builtin context, the table entry, the command-set
    /// publication, and the terminal projection.
    ///
    /// - Parameters:
    ///   - session: The root Router session to mount.
    ///   - composition: What the composition pipeline built for it.
    ///   - workingDirectory: The validated session working directory.
    ///   - additionalRoots: The session's additional confinement roots,
    ///     in wire order.
    ///   - indexRecorded: Whether the `sessions.jsonl` record already
    ///     exists, so the first prompt knows whether to append it (§9).
    /// - Returns: The session id and the announced `configOptions` list.
    /// - Throws: Whatever the project-registry record throws.
    func activateSession(
        _ session: any RoutedSession,
        composition: SessionComposition,
        workingDirectory: URL,
        additionalRoots: [URL],
        indexRecorded: Bool
    ) async throws -> (sessionId: SessionId, configOptions: [SessionConfigOption]) {
        // Register the cwd (plan.md §4.5).
        try ProjectRegistry(directory: composition.userLayerRoot)
            .recordSessionStart(workingDirectory: workingDirectory)

        let sessionId = SessionId(rawValue: session.id.description)

        // Assemble the command registry now the session exists (plan.md
        // §14.1): the six builtins capture a context bound to the live
        // session and, through it, to the registry that carries them, so
        // `/help` can list every registered command. The reserved-name rule
        // is enforced by the registry merge.
        let commandContext = BuiltinCommandContext(
            workingDirectory: workingDirectory,
            configuration: composition.configuration,
            instructions: composition.instructions,
            modelName: residentProfile.standard.chosen.stringValue,
            profileName: residentProfile.definitionName,
            dotfolderName: name,
            userLayerRoot: composition.userLayerRoot)
        let commands = CommandRegistry(
            builtins: BuiltinCommands.make(context: commandContext),
            providers: composition.commandProviders,
            workingDirectory: workingDirectory)
        await commands.load()
        commandContext.bind(
            BuiltinCommandContext.Binding(
                session: session,
                sessionId: sessionId,
                transcriptDirectory: session.recordingDirectory,
                registry: commands))

        // The first announcement of the config-option list (plan.md
        // §15): one select over the profile's chat slots, defaulting to
        // the standard slot the session was just composed from. The
        // announced state is recorded so the divergence check compares
        // against what the client actually saw.
        let configOptions = ConfigOptions.options(
            profile: residentProfile, selectedSlot: ConfigOptions.defaultSlot)

        sessions[sessionId] = ActiveSession(
            session: session,
            configuration: composition.configuration,
            instructions: composition.instructions,
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            transcriptDirectory: session.recordingDirectory,
            surface: composition.surface,
            commands: commands,
            selectedSlot: ConfigOptions.defaultSlot,
            announcedConfigOptions: configOptions,
            activeTurn: nil,
            indexRecorded: indexRecorded)

        // The command set publishes after the response, and again on
        // every registry change (plan.md §14.4).
        publishAvailableCommands(from: commands, sessionId: sessionId)

        startTerminalProjection(over: composition.surface, sessionId: sessionId)

        return (sessionId, configOptions)
    }

    /// Starts the session's terminal projection (plan.md §11.8): the
    /// one consumer loop over the host-owned shell output stream,
    /// posting each terminal update through the bound connection. A
    /// session with no shell mount, or an agent with no bound
    /// connection, starts nothing. The loop ends when
    /// ``markSessionClosed(_:)`` finishes the stream.
    ///
    /// - Parameters:
    ///   - surface: The session's mounted surface.
    ///   - sessionId: The session the updates belong to.
    private func startTerminalProjection(over surface: SessionSurface, sessionId: SessionId) {
        guard let shellOutput = surface.shellOutput, let connection = boundConnection else {
            return
        }
        TerminalStream.start(over: shellOutput) { update in
            await connection.post(update, in: sessionId)
        }
    }

    /// Resolves the per-cwd configuration one session request starts from
    /// (plan.md §2.2, §4.1): the config layer, the user layer root, and
    /// the recording root.
    ///
    /// - Parameter workingDirectory: The validated session working
    ///   directory.
    /// - Returns: The resolved context.
    /// - Throws: Whatever the config load throws.
    func loadSessionContext(workingDirectory: URL) throws -> LoadedSessionContext {
        let loader = ConfigurationLoader(
            name: name,
            workingDirectory: workingDirectory,
            userDirectory: userDirectory,
            environment: environment)
        let loaded = try loader.load()
        let userLayerRoot = SessionSetup.userLayerRoot(of: loader.stack)
        return LoadedSessionContext(
            loader: loader,
            loaded: loaded,
            userLayerRoot: userLayerRoot,
            transcriptRoot: loaded.configuration.transcripts.location.recordingRoot(
                workingDirectory: workingDirectory,
                name: name,
                userDirectory: userLayerRoot))
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
        try await composeSession(
            from: loadSessionContext(workingDirectory: workingDirectory),
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            clientMCPServers: clientMCPServers)
    }

    /// Composes one session over an already-resolved configuration
    /// (plan.md §7.1): assemble the instructions, then connect the MCP
    /// servers and build the tool roster through the catalog.
    ///
    /// - Parameters:
    ///   - context: The resolved per-cwd configuration.
    ///   - workingDirectory: The validated session working directory.
    ///   - additionalRoots: The session's additional confinement roots,
    ///     in wire order.
    ///   - clientMCPServers: The client's session-scoped MCP servers, in
    ///     wire order (§7.3).
    /// - Returns: The composed inputs of `makeSession`.
    /// - Throws: Whatever the instructions assembly or the tool
    ///   composition throws.
    func composeSession(
        from context: LoadedSessionContext,
        workingDirectory: URL,
        additionalRoots: [URL],
        clientMCPServers: [FoundationModelsACP.MCPServer]
    ) async throws -> SessionComposition {
        let catalogContext = CatalogContext(
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            configuration: context.loaded.configuration,
            profile: residentProfile,
            clientMCPServers: clientMCPServers)

        // One watched registry serves the preload assembly here and the
        // slash-command source below (plan.md §14.2). `watch: true` is
        // what makes its `commandUpdates` non-nil.
        let skills = ToolCatalog.makeSkillsRegistry(context: catalogContext)
        let instructions = try InstructionsAssembler(
            stack: context.loader.stack, workingDirectory: workingDirectory
        ).assemble(skills: skills)

        let surface = try await ToolCatalog.sessionSurface(context: catalogContext)

        return SessionComposition(
            configuration: context.loaded.configuration,
            instructions: instructions.text,
            surface: surface,
            commandProviders: makeCommandProviders(surface: surface, skills: skills),
            userLayerRoot: context.userLayerRoot,
            transcriptRoot: context.transcriptRoot)
    }

    /// Assembles the registry's later sources in precedence order
    /// (plan.md §14.1): the catalog's linked `SlashCommandProviding`
    /// conformers first, then the registered providers, then the skills
    /// source last, so skills win a non-builtin collision.
    ///
    /// - Parameters:
    ///   - surface: The mounted tool surface whose conformers join.
    ///   - skills: The session's skills registry, or `nil` when the
    ///     `skills:` section is off.
    /// - Returns: The providers, in precedence order.
    private func makeCommandProviders(
        surface: SessionSurface, skills: SkillsRegistry?
    ) -> [any SlashCommandProviding] {
        var providers = surface.tools.compactMap { $0 as? any SlashCommandProviding }
        providers.append(contentsOf: commandProviders)
        if let skills {
            providers.append(SkillCommandSource(registry: skills))
        }
        return providers
    }

    /// Publishes the session's command set at session start and on
    /// every registry change (plan.md §14.4): the initial publication
    /// goes out after the `session/new` response, and each provider
    /// update republishes through the same sink.
    ///
    /// - Parameters:
    ///   - commands: The session's loaded registry.
    ///   - sessionId: The session the updates belong to.
    func publishAvailableCommands(from commands: CommandRegistry, sessionId: SessionId) {
        guard let connection = boundConnection else { return }
        connection.afterRespondingToCurrentRequest {
            await commands.beginPublishing { commandSet in
                await connection.post(
                    .availableCommandsUpdate(
                        AvailableCommandsUpdate(
                            availableCommands: CommandRegistry.availableCommands(for: commandSet))),
                    in: sessionId)
            }
        }
    }
}

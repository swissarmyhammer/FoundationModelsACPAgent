import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import FoundationModelsSkills
import Logging

/// Whether a session can accept a new prompt (plan.md §7.1). `idle` means
/// "ready for a new prompt"; a `session/prompt` that arrives while the
/// session is `busy` is a client error, not a queue entry — the composer
/// owns queueing, and Router's own prompt queue is never shown over ACP.
/// A `closed` session is resumable, not promptable (plan.md §10.1).
enum SessionAvailability: Equatable, Sendable {
    /// The session is ready for a new prompt.
    case idle

    /// A prompt is in flight.
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
    /// The Router session that answers this ACP session's prompts.
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

    /// The running prompt's state owner, or `nil` when no prompt is in
    /// flight (plan.md §8.2). `session/cancel` reaches the prompt through
    /// this reference.
    var activePrompt: PromptStateOwner?

    /// The running prompt's elicitation relay, or `nil` when no prompt is in
    /// flight (plan.md §16). `session/cancel` and `session/close` answer
    /// every pending elicitation with `cancel` through this reference,
    /// so the suspended tool resumes before the `idle` terminator.
    var activeElicitationRelay: ElicitationRelay?

    /// The session's descendants — its forks and, later, its spawned
    /// sub-agents (plan.md §10.1). `session/close` closes each one, so no
    /// orphan keeps a run or a submission in the model queue after the
    /// parent goes. This iteration holds forks; the path stays open for the
    /// spawned sessions a later Multitool agents capability starts.
    var descendants: [any RoutedSession] = []

    /// Whether `session/close` released this session (plan.md §10.1).
    var isClosed = false

    /// Whether the `sessions.jsonl` record was written. The first prompt
    /// writes it, deferred from `session/new` by §9's zero-prompt rule.
    var indexRecorded = false

    /// The retained history of the session (plan.md §7.4, §8.3): each
    /// `session/update` that the agent sent for the session, merged, with
    /// its id. The `session/new` or `session/resume` response seeds it. A
    /// compaction changes only the model context, never this history.
    /// `session/resume` replays it, and ``SessionHistoryFile`` keeps it on
    /// disk for a new process.
    var history = SessionMergeEngine()

    /// Whether the session can accept a new prompt. Derived, so the
    /// stored prompt reference stays the one source of the busy state.
    var availability: SessionAvailability {
        if isClosed {
            return .closed
        }
        return activePrompt == nil ? .idle : .busy
    }

    /// Inserts the prompt of `request` as the user message of the session:
    /// the history gets the `user_message` echo at once, and the connection
    /// sends the echo after the response to the current request.
    ///
    /// Call it in the handler of the `session/prompt` request, after each
    /// check that can refuse the prompt and before the prompt defers its
    /// work, so the echo goes out first.
    ///
    /// - Parameters:
    ///   - request: The prompt request.
    ///   - connection: The connection that sends the echo.
    /// - Returns: The id of the user message, for the prompt response.
    mutating func insertUserMessage(
        _ request: PromptRequest, through connection: AgentSideConnection
    ) -> MessageId {
        connection.insertUserMessage(request, into: &history)
    }
}

/// The per-session composition helpers of `session/new` (plan.md §7.1):
/// cwd validation and the config → instructions → tools pipeline that
/// feeds `profile.standard.makeSession(...)`.
enum SessionSetup {
    /// The prefix every absolute path starts with.
    private static let absolutePathPrefix = "/"

    /// The request field one wire path came from (plan.md §7.1, §7.2).
    /// A refusal names the field, so a person reads which part of the
    /// request failed rather than guessing.
    enum PathField: String {
        /// The session working directory: the `cwd` of `session/new` and
        /// `session/resume`, and the project filter of `session/list`.
        case cwd

        /// One entry of the ordered `additionalDirectories` list.
        case additionalDirectories
    }

    /// Whether `path` is absolute.
    ///
    /// The ACP schema types a path as a plain string and states the
    /// absolute rule in prose only, so no decoder enforces it. This agent
    /// owns the file system, so this agent is the only judge, and this is
    /// the one place the rule is written down.
    ///
    /// - Parameter path: The candidate path string.
    /// - Returns: `true` when `path` begins with `/`.
    fileprivate static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix(absolutePathPrefix)
    }

    /// Validates that `path` is absolute and returns it as a directory
    /// URL. `cwd` MUST be absolute (plan.md §7.1): it keys the config
    /// layer, the AGENTS.md walk, and the transcript directory, and a
    /// relative path would key them off the process cwd instead.
    ///
    /// - Parameters:
    ///   - path: The path string of the request.
    ///   - field: The request field `path` came from, named in the
    ///     refusal so the client learns which one to fix.
    /// - Returns: The working directory URL.
    /// - Throws: ``RequestError/relativePath(field:)``
    ///   when `path` is relative.
    static func validatedWorkingDirectory(
        path: String, field: PathField
    ) throws(RequestError) -> URL {
        guard isAbsolute(path) else {
            throw .relativePath(field: field)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Converts the wire `additionalDirectories` path strings to
    /// confinement root URLs, in wire order (plan.md §7.2). Each entry
    /// goes through the same ``validatedWorkingDirectory(path:field:)``
    /// check the `cwd` goes through, under its own field name.
    ///
    /// A relative entry refuses the whole request. The wire decode
    /// carries every entry as sent, so a skip here would drop a
    /// confinement root the client asked for and never say so, and the
    /// session would then run with a boundary neither side agreed on.
    ///
    /// - Parameter paths: The requested directory paths, in wire order.
    /// - Returns: The confinement root URLs, in the same order.
    /// - Throws: ``RequestError/relativePath(field:)``
    ///   for the first relative entry.
    static func additionalRoots(fromPaths paths: [String]) throws(RequestError) -> [URL] {
        try paths.map { path throws(RequestError) in
            try validatedWorkingDirectory(path: path, field: .additionalDirectories)
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

extension RequestError {
    /// The `reason` a relative-path refusal reports in `data`.
    private static let mustBeAbsoluteReason = "must be absolute"

    /// The relative-path refusal (plan.md §7.1, §7.2): JSON-RPC invalid
    /// params naming the field that failed and why. This is the `data`
    /// shape `FoundationModelsACP` pins in
    /// `RequestErrorTests.theWireFormRoundTrips`.
    ///
    /// - Parameter field: The request field the relative path came from.
    /// - Returns: The typed invalid-params error.
    static func relativePath(field: SessionSetup.PathField) -> RequestError {
        RequestError(
            code: .invalidParams,
            message: RequestError.invalidParams.message,
            data: .object([
                "field": .string(field.rawValue),
                "reason": .string(mustBeAbsoluteReason),
            ]))
    }
}

extension AbsolutePath {
    /// The wire path for `rawValue`, or `nil` when `rawValue` is not
    /// absolute.
    ///
    /// The wire type carries whatever string it was given, so this is the
    /// one door for every projection that must DROP a path it cannot put
    /// on the wire — a damaged stored record, or a tool report the agent
    /// only relays. A path that arrives in a request is refused instead,
    /// through ``SessionSetup/validatedWorkingDirectory(path:field:)``.
    ///
    /// - Parameter rawValue: The candidate path string.
    /// - Returns: The path, or `nil` when it is relative.
    init?(absolute rawValue: String) {
        guard SessionSetup.isAbsolute(rawValue) else {
            return nil
        }
        self.init(rawValue: rawValue)
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

/// What one mount of a session announces in the `session/new` or
/// `session/resume` response (ACP schema-v2.0.0-alpha.7): the session id,
/// the first command list, and the first config-option list. A later
/// `available_commands_update` or `config_option_update` replaces a list.
struct SessionActivation {
    /// The ACP session id: the root Router session's ULID.
    let sessionId: SessionId

    /// The merged command set of the session registry, as the wire list.
    let availableCommands: [AvailableCommand]

    /// The config-option list (plan.md §15).
    let configOptions: [SessionConfigOption]
}

extension RoutedACPAgent {
    /// Creates one root Router session for `params.cwd` (plan.md §7.1).
    ///
    /// The ACP `sessionId` IS the root Router session's ULID, serialized —
    /// there is no mapping table (§4.2). The cwd is registered in the
    /// project registry now; the `sessions.jsonl` index record waits for
    /// the first recorded activity, because §9's zero-prompt rule makes a
    /// persisted transcript the listability test.
    ///
    /// The request runs in one server span, and it writes one "enter" record
    /// when it starts, because the tool and MCP server composition can take a
    /// long time (``RequestTracing``). The span carries the id of the new
    /// session.
    ///
    /// - Parameter params: The request: the absolute `cwd`, the ordered
    ///   `additionalDirectories`, and the client's session-scoped
    ///   `mcpServers` (§7.2, §7.3).
    /// - Returns: The response carrying the new sessionId, the
    ///   `availableCommands` list and the `configOptions` list.
    /// - Throws: The order rule's invalid-request error,
    ///   `RequestError.invalidParams` for a relative cwd, or whatever the
    ///   composition pipeline throws.
    public func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        try await RequestTracing.withEnteredRequestSpan(
            ACPAgentTelemetry.SpanName.sessionNew, method: ACPMethod.sessionNew, sessionId: nil,
            meta: params.meta, logger: ACPAgentTelemetry.logger(.session)
        ) { span in
            let response = try await createSession(params)
            span.attributes[ACPAgentTelemetry.AttributeKey.sessionId] = response.sessionId.rawValue
            return response
        }
    }

    /// Creates the root Router session of one `session/new`: the work of
    /// ``newSession(_:)``.
    ///
    /// - Parameter params: The `session/new` request.
    /// - Returns: The response carrying the new sessionId, the
    ///   `availableCommands` list and the `configOptions` list.
    /// - Throws: The errors that ``newSession(_:)`` names.
    private func createSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        try requireInitialized(before: ACPMethod.sessionNew)
        let workingDirectory = try SessionSetup.validatedWorkingDirectory(
            path: params.cwd.rawValue, field: .cwd)
        let additionalRoots = try SessionSetup.additionalRoots(
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
        // `session/new`. The budget starts automatic compaction: the
        // fractions come from the `compaction:` section and the limit
        // from the model's resolved context (plan.md §2.4). The repetition
        // detector takes the `repetition:` section.
        let session = residentProfile.standard.makeBudgetedSession(
            instructions: composition.instructions,
            workingDirectory: workingDirectory,
            recordingRoot: composition.transcriptRoot,
            tools: composition.surface.tools,
            compaction: composition.configuration.compaction,
            repetition: composition.configuration.repetition)

        // The `sessions.jsonl` index record is NOT written here: the
        // prompt task appends it at the first recorded activity,
        // with the title (§9).
        let activation = try await activateSession(
            session,
            composition: composition,
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            indexRecorded: false,
            history: SessionMergeEngine())

        let response = NewSessionResponse(
            sessionId: activation.sessionId,
            availableCommands: activation.availableCommands,
            configOptions: activation.configOptions)
        sessions[activation.sessionId]?.history.seed(from: response)
        return response
    }

    /// Mounts one made or restored Router session into the agent (plan.md
    /// §7.1, §7.4): the project-registry record, the command registry with
    /// its bound builtin context, the table entry with its retained
    /// history, the command-set publication, and the terminal projection.
    ///
    /// - Parameters:
    ///   - session: The root Router session to mount.
    ///   - composition: What the composition pipeline built for it.
    ///   - workingDirectory: The validated session working directory.
    ///   - additionalRoots: The session's additional confinement roots,
    ///     in wire order.
    ///   - indexRecorded: Whether the `sessions.jsonl` record already
    ///     exists, so the first prompt knows whether to append it (§9).
    ///   - history: The retained history of the session: empty for a new
    ///     session, the kept history for a resumed one.
    /// - Returns: The session id, and the command list and the
    ///   config-option list that the response announces.
    /// - Throws: Whatever the project-registry record throws.
    func activateSession(
        _ session: any RoutedSession,
        composition: SessionComposition,
        workingDirectory: URL,
        additionalRoots: [URL],
        indexRecorded: Bool,
        history: SessionMergeEngine
    ) async throws -> SessionActivation {
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
            activePrompt: nil,
            activeElicitationRelay: nil,
            indexRecorded: indexRecorded,
            history: history)
        recordActiveSessions()

        // The response announces the first command list, and each registry
        // change after it publishes the new list (plan.md §14.4).
        publishAvailableCommands(from: commands, sessionId: sessionId)

        startTerminalProjection(over: composition.surface, sessionId: sessionId)

        return SessionActivation(
            sessionId: sessionId,
            availableCommands: CommandRegistry.availableCommands(for: await commands.commands),
            configOptions: configOptions)
    }

    /// Starts the session's terminal projection (plan.md §11.8): the
    /// one consumer loop over the host-owned shell output stream,
    /// posting each terminal update through the bound connection and
    /// keeping it in the retained history (``historySink(for:connection:)``).
    /// A session with no shell mount, or an agent with no bound
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
        TerminalStream.start(over: shellOutput, send: historySink(for: sessionId, connection: connection))
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
        let skills = await ToolCatalog.makeSkillsRegistry(context: catalogContext)
        let instructions = try await InstructionsAssembler(
            stack: context.loader.stack, workingDirectory: workingDirectory
        ).assemble(skills: skills)

        let surface = try await ToolCatalog.sessionSurface(
            context: catalogContext, skillsRegistry: skills)

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

    /// Publishes each change of the session's command set (plan.md §14.4):
    /// the `session/new` or `session/resume` response announces the first
    /// list (ACP schema-v2.0.0-alpha.7), and the registry starts to publish
    /// after that response. A publication sends an
    /// `available_commands_update` only when its list differs from the
    /// list that the client has (``publishCommandList(_:of:through:)``),
    /// so no update repeats the list of the response.
    ///
    /// The closures keep the agent, the connection and the registry weakly,
    /// as the agent keeps the connection (task `^173qn8n`):
    ///
    /// - The registry keeps the sink for the life of the session entry. A
    ///   strong reference to the connection would keep the connection, and
    ///   through it the agent and its models, after the connection closed.
    /// - Upstream, the connection releases the deferred work after it ran.
    ///   The skills watcher that `session/new` starts lives on, so a strong
    ///   reference to the registry would still keep the registry, its
    ///   builtins, the session they read and the models of the profile for
    ///   as long as the publisher lives.
    ///
    /// The session entry keeps the registry for as long as it publishes.
    ///
    /// - Parameters:
    ///   - commands: The session's loaded registry.
    ///   - sessionId: The session the updates belong to.
    func publishAvailableCommands(from commands: CommandRegistry, sessionId: SessionId) {
        guard let connection = boundConnection else { return }
        connection.afterRespondingToCurrentRequest { [weak self, weak connection, weak commands] in
            await commands?.beginPublishing { [weak self, weak connection] commandSet in
                guard let connection else { return }
                await self?.publishCommandList(
                    CommandRegistry.availableCommands(for: commandSet), of: sessionId, through: connection)
            }
        }
    }

    /// Sends one `available_commands_update` with `list`, and keeps it in
    /// the retained history, when `list` differs from the list that the
    /// client has. The history holds that list: the response seeded it,
    /// and each update after the response changed it.
    ///
    /// - Parameters:
    ///   - list: The new command list.
    ///   - sessionId: The session the list belongs to.
    ///   - connection: The bound connection that sends the update.
    private func publishCommandList(
        _ list: [AvailableCommand], of sessionId: SessionId, through connection: AgentSideConnection
    ) async {
        guard let entry = sessions[sessionId], entry.history.availableCommands != list else {
            return
        }
        let update = SessionUpdate.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: list))
        recordInHistory(update, of: sessionId)
        await connection.post(update, in: sessionId)
    }
}

extension RoutedLLM {
    /// Vends one session with the derived auto-compaction budget
    /// (plan.md §2.4): `compaction` carries the fractions and the
    /// tool-output cap, and this model carries the resolved working
    /// context the fractions measure against. `session/new` and the
    /// model-slot switch both vend through this one door, so the two
    /// paths cannot drift.
    ///
    /// - Parameters:
    ///   - instructions: The session's assembled instructions text.
    ///   - workingDirectory: The session working directory.
    ///   - recordingRoot: The per-session recording root.
    ///   - tools: The tools the model can call.
    ///   - compaction: The `compaction:` section the budget derives from.
    ///   - repetition: The `repetition:` section the repetition detector of
    ///     the session takes (task ^k51h6bb).
    /// - Returns: A new session over this model, with automatic
    ///   compaction on. The compaction keeps each skill that the model
    ///   loads with `use skill` (``SkillOutputProtection``).
    func makeBudgetedSession(
        instructions: String,
        workingDirectory: URL,
        recordingRoot: URL,
        tools: [any FoundationModels.Tool],
        compaction: CompactionConfiguration,
        repetition: RepetitionConfiguration
    ) -> any RoutedSession {
        // The resolved context decides two things that a reader cannot see
        // otherwise: the fold point of the compaction, and the token ceiling
        // of each generation call, which Router derives from the same number.
        // A prompt that ends `_truncated` is read against this record.
        // `notice`, not `info`: a reader of a long run looks for this record
        // after the run, and a backend often keeps only `notice` and more.
        ACPAgentTelemetry.logger(.session).notice(
            "The session has its token budget.",
            metadata: [
                ACPAgentTelemetry.LogMetadataKey.contextTokens: "\(contextTokens)",
                ACPAgentTelemetry.LogMetadataKey.compactionTriggerFraction: "\(compaction.trigger)",
                ACPAgentTelemetry.LogMetadataKey.compactionTargetFraction: "\(compaction.target)",
            ])
        return makeSession(
            instructions: instructions,
            workingDirectory: workingDirectory,
            recordingRoot: recordingRoot,
            tools: tools,
            budget: TokenBudget(
                limit: contextTokens,
                trigger: compaction.trigger,
                target: compaction.target,
                hardCeiling: compaction.hardCeiling,
                toolOutputLimit: compaction.toolOutputLimit),
            compactionPrompt: .default,
            toolOutputProtection: SkillOutputProtection.rule,
            repetitionDetection: repetition.detection)
    }
}

import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import FoundationModelsSkills
import Logging

/// Whether a session has a prompt in flight. A session accepts a new
/// prompt in both `idle` and `busy`: each prompt is mail, and it waits in
/// the mail queue of the session (elicitation-plan task 3). A `closed`
/// session is resumable, not promptable.
enum SessionAvailability: Equatable, Sendable {
    /// No prompt is in flight.
    case idle

    /// At least one prompt is in flight.
    case busy

    /// `session/close` released the session. The transcript stays, so
    /// `session/resume` can bring it back.
    case closed
}

/// One live session in the agent's table: the root Router
/// session plus everything the session composed per cwd — its config, its
/// assembled instructions, its confinement root set, its transcript
/// directory, and the mounted tool surface whose pool the session
/// lifecycle shuts down at close. One ACP session is one root Router
/// session, with the same ULID.
struct ActiveSession: Sendable {
    /// The Router session that answers this ACP session's prompts.
    /// Retaining it is what keeps the resident profile alive for this
    /// session's lifetime. Born as the root session from the standard
    /// slot; a model-slot switch replaces it with one
    /// vended from the selected slot's handle.
    var session: any RoutedSession

    /// The merged per-cwd configuration this session was composed from.
    /// The project layer resolves per session, from the session cwd,
    /// never from the process cwd.
    let configuration: AgentConfiguration

    /// The assembled instructions text the session was born with. A
    /// running session keeps this text through each
    /// compaction fold; only a new session re-assembles.
    let instructions: String

    /// The session working directory — the base for relative paths and
    /// the root set's first member.
    let workingDirectory: URL

    /// The session's additional confinement roots, in wire order.
    /// They extend confinement only; they never change
    /// ``workingDirectory``.
    let additionalRoots: [URL]

    /// The session's own transcript directory,
    /// `<recording root>/<sessionId>/`.
    let transcriptDirectory: URL

    /// The mounted tool surface. The session-close task calls
    /// `surface.serverPool.shutdownAll()` after the session sweep, never
    /// before, so the settling runs still have their transports.
    let surface: SessionSurface

    /// The session's slash-command registry, assembled
    /// at session creation. The `prompt()` handler dispatches a leading
    /// `/name` through it before anything touches the session.
    let commands: CommandRegistry

    /// The model slot ``session`` was vended from. Only
    /// `standard` and `flash` occur; embedding is not a chat slot.
    var selectedSlot: ModelSlot

    /// The config-option state the client last saw:
    /// what `session/new` or `session/set_config_option` answered, or a
    /// `config_option_update` pushed. The divergence check compares the
    /// truth against this baseline.
    var announcedConfigOptions: [SessionConfigOption]

    /// The user presence that the session got when the agent opened it
    /// (``RoutedACPAgent/userPresence``). A model slot switch gives it to
    /// the replacement session, so the presence of the session does not
    /// change.
    let userPresence: UserPresence

    /// The state owner of each prompt in flight, in the order of
    /// acceptance. `session/cancel` and `session/close` reach the prompts
    /// through it.
    var openPrompts: [PromptStateOwner] = []

    /// The `state_update` of the session over all its open prompts.
    let stateLedger: SessionStateLedger

    /// The one reader of the events of the session, from its open to its
    /// close (``SessionProjector``). It holds the elicitation relay of the
    /// session: `session/cancel` and `session/close` answer every pending
    /// elicitation with `cancel` through it.
    let projector: SessionProjector

    /// The session's descendants — its forks. `session/close`
    /// closes each one, so no orphan keeps a run or a submission in the model
    /// queue after the parent goes. The runs of the `agents` tool are not
    /// here: `SessionSurface.stopAgentRuns()` stops them.
    var descendants: [any RoutedSession] = []

    /// Whether the session is replay-only: `session/resume` found its
    /// working directory or one of its additional roots missing. The agent
    /// never makes a session directory, so the session mounts no tool
    /// surface, writes nothing for the session, and refuses each prompt.
    let isReplayOnly: Bool

    /// Whether `session/close` released this session.
    var isClosed = false

    /// Whether the `sessions.jsonl` record was written. The first prompt
    /// writes it, not `session/new`: a session with zero prompts is not
    /// listable, so a persisted transcript is the listability test.
    var indexRecorded = false

    /// The retained history of the session: each
    /// `session/update` that the agent sent for the session, merged, with
    /// its id. The `session/new` or `session/resume` response seeds it. A
    /// compaction changes only the model context, never this history.
    /// `session/resume` replays it, and ``SessionHistoryFile`` keeps it on
    /// disk for a new process. The `user_message` recorder of the connection
    /// shares it (``RetainedHistory``).
    let retainedHistory: RetainedHistory

    /// A copy of the retained history as it is now.
    var history: SessionMergeEngine {
        retainedHistory.snapshot
    }

    /// Whether the session has a prompt in flight. Derived, so the
    /// stored prompt list stays the one source of the busy state.
    var availability: SessionAvailability {
        if isClosed {
            return .closed
        }
        return openPrompts.isEmpty ? .idle : .busy
    }

    /// Inserts the prompt of `request` as the user message of the session.
    /// After the success response to the current request, the connection
    /// gives the `user_message` echo to the retained history and then sends
    /// the echo. Thus the history gets the message after the handler
    /// returns. The prompt defers its work after this call, so the history
    /// holds the message before the first update of the prompt.
    ///
    /// Call it in the handler of the `session/prompt` request, after each
    /// check that can refuse the prompt and before the prompt defers its
    /// work, so the echo goes out first.
    ///
    /// - Parameters:
    ///   - request: The prompt request.
    ///   - messageId: The id of the user message: the description of the
    ///     `MailID` of the prompt, or `nil` for a new id.
    ///   - connection: The connection that sends the echo.
    /// - Returns: The id of the user message, for the prompt response.
    func insertUserMessage(
        _ request: PromptRequest, messageId: MessageId? = nil, through connection: AgentSideConnection
    ) -> MessageId {
        let history = retainedHistory
        return connection.insertUserMessage(request, messageId: messageId) { update in history.apply(update) }
    }
}

/// The per-session composition helpers of `session/new`:
/// cwd validation and the config → instructions → tools pipeline that
/// feeds `profile.standard.makeSession(...)`.
enum SessionSetup {
    /// The prefix every absolute path starts with.
    private static let absolutePathPrefix = "/"

    /// The request field one wire path came from.
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
    /// URL. `cwd` MUST be absolute: it keys the config
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

    /// Why a request directory cannot hold a session. The raw value is the
    /// `reason` that the refusal reports in `data`.
    enum DirectoryDefect: String {
        /// The file system holds nothing at the path.
        case doesNotExist = "does not exist"

        /// The file system holds a file, not a directory, at the path.
        case notADirectory = "is not a directory"
    }

    /// One request directory that fails the existence check, with the
    /// request field it came from and the reason.
    struct DirectoryFailure {
        /// The request directory that fails the check.
        let directory: URL

        /// The request field the directory came from.
        let field: PathField

        /// Why the directory cannot hold a session.
        let defect: DirectoryDefect
    }

    /// The defect of `directory`, or `nil` when it is an existing
    /// directory. ``PathKind`` does the probe, so a symbolic link to a
    /// directory is a directory.
    ///
    /// - Parameter directory: The request directory.
    /// - Returns: The defect, or `nil`.
    static func defect(of directory: URL) -> DirectoryDefect? {
        switch PathKind.of(directory) {
        case .missing:
            return .doesNotExist
        case .notADirectory:
            return .notADirectory
        case .directory:
            return nil
        }
    }

    /// The first directory of a session that fails the existence check,
    /// in request order: the cwd first, then each additional root in wire
    /// order. This walk is the one statement of which directories a
    /// session needs.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session working directory.
    ///   - additionalRoots: The additional confinement roots, in wire order.
    /// - Returns: The first failure, or `nil` when each directory exists.
    static func firstDirectoryFailure(
        workingDirectory: URL, additionalRoots: [URL]
    ) -> DirectoryFailure? {
        let requested =
            [(workingDirectory, PathField.cwd)]
            + additionalRoots.map { ($0, PathField.additionalDirectories) }
        return requested.lazy.compactMap { directory, field in
            defect(of: directory).map {
                DirectoryFailure(directory: directory, field: field, defect: $0)
            }
        }.first
    }

    /// Validates that the working directory and each additional root of a
    /// session are existing directories.
    ///
    /// The agent never makes a session directory. A composition that runs
    /// over a missing directory makes it: the code context index, for
    /// example, makes `<cwd>/.code-context` and each missing parent. So
    /// `session/new` refuses a missing directory before it composes
    /// anything.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session working directory.
    ///   - additionalRoots: The additional confinement roots, in wire order.
    /// - Throws: ``RequestError/missingDirectory(_:field:defect:)`` for the
    ///   first directory that fails the check.
    static func requireExistingDirectories(
        workingDirectory: URL, additionalRoots: [URL]
    ) throws(RequestError) {
        guard
            let failure = firstDirectoryFailure(
                workingDirectory: workingDirectory, additionalRoots: additionalRoots)
        else {
            return
        }
        throw .missingDirectory(failure.directory, field: failure.field, defect: failure.defect)
    }

    /// Whether the working directory and each additional root of a session
    /// are existing directories. `session/resume` reads it: a resumed
    /// session with a missing directory is replay-only, not refused.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session working directory.
    ///   - additionalRoots: The additional confinement roots.
    /// - Returns: `true` when no directory fails the check.
    static func allDirectoriesExist(workingDirectory: URL, additionalRoots: [URL]) -> Bool {
        firstDirectoryFailure(workingDirectory: workingDirectory, additionalRoots: additionalRoots)
            == nil
    }

    /// Converts the wire `additionalDirectories` path strings to
    /// confinement root URLs, in wire order. Each entry
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
    /// production. `ProjectRegistry` lives there, and the
    /// `home` transcript location resolves against it.
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

    /// The relative-path refusal: JSON-RPC invalid
    /// params naming the field that failed and why. This is the `data`
    /// shape `FoundationModelsACP` pins in
    /// `RequestErrorTests.theWireFormRoundTrips`.
    ///
    /// - Parameter field: The request field the relative path came from.
    /// - Returns: The typed invalid-params error.
    static func relativePath(field: SessionSetup.PathField) -> RequestError {
        pathRefusal(field: field, reason: mustBeAbsoluteReason)
    }

    /// The missing-directory refusal: JSON-RPC invalid params naming the
    /// field, the path and the reason. The agent never makes a session
    /// directory, so a request directory must exist.
    ///
    /// - Parameters:
    ///   - directory: The refused request directory.
    ///   - field: The request field the directory came from.
    ///   - defect: Why the directory cannot hold a session.
    /// - Returns: The typed invalid-params error.
    static func missingDirectory(
        _ directory: URL, field: SessionSetup.PathField, defect: SessionSetup.DirectoryDefect
    ) -> RequestError {
        pathRefusal(field: field, reason: defect.rawValue, path: directory)
    }

    /// The one builder of a request-path refusal: JSON-RPC invalid params
    /// with `data` that names the field, the reason and, when given, the
    /// refused path.
    ///
    /// - Parameters:
    ///   - field: The request field that failed.
    ///   - reason: Why the request path is refused.
    ///   - path: The refused path, or `nil` when the refusal does not name
    ///     it.
    /// - Returns: The typed invalid-params error.
    private static func pathRefusal(
        field: SessionSetup.PathField, reason: String, path: URL? = nil
    ) -> RequestError {
        var data: [String: FoundationModelsACP.JSONValue] = [
            "field": .string(field.rawValue),
            "reason": .string(reason),
        ]
        data["path"] = path.map { .string($0.path) }
        return RequestError(
            code: .invalidParams, message: RequestError.invalidParams.message,
            data: .object(data))
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
/// of the session cwd: the loader whose stack the instructions assembly
/// reads, the merged configuration, the user layer root, and the resolved
/// recording root.
///
/// `session/new` resolves and composes in one motion; `session/resume`
/// resolves first, runs the cwd pre-check against ``transcriptRoot``, and
/// composes only after the check passes.
struct LoadedSessionContext {
    /// The loader whose dotfolder stack the instructions assembly reads.
    let loader: ConfigurationLoader

    /// The merged and decoded configuration.
    let loaded: LoadedConfiguration

    /// The user layer root the stack resolved.
    let userLayerRoot: URL

    /// The resolved recording root: `<cwd>/.<name>/transcripts/` by
    /// default.
    let transcriptRoot: URL
}

/// What one `session/new` composed before the session was made:
/// the merged config, the assembled instructions, the
/// mounted tool surface, and the resolved recording root.
struct SessionComposition {
    /// The merged per-cwd configuration.
    let configuration: AgentConfiguration

    /// The assembled instructions text.
    let instructions: String

    /// The mounted tool surface.
    let surface: SessionSurface

    /// The later slash-command sources, in precedence order:
    /// the catalog's linked conformers, then the registered providers, then
    /// the skills source. The registry is assembled in `newSession`, once the
    /// live session the builtins capture exists.
    let commandProviders: [any SlashCommandProviding]

    /// The user layer root the stack resolved, for the project registry
    /// and the `home` transcript location.
    let userLayerRoot: URL

    /// The recording root `makeSession(recordingRoot:)` receives; Router
    /// records the session to `<transcriptRoot>/<sessionId>/`.
    let transcriptRoot: URL

    /// Whether the composition is the one of a replay-only resume: no
    /// instructions, no tool surface, and no command source. The mount
    /// then writes no project-registry record and announces no command.
    let isReplayOnly: Bool
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

    /// The config-option list.
    let configOptions: [SessionConfigOption]
}

extension RoutedACPAgent {
    /// Creates one root Router session for `params.cwd`.
    ///
    /// The ACP `sessionId` IS the root Router session's ULID, serialized —
    /// there is no mapping table, because a mapping table can drift and
    /// a resume would then restore the wrong conversation. The cwd is
    /// registered in the project registry now; the `sessions.jsonl` index
    /// record waits for the first recorded activity, because a session
    /// with zero prompts is not listable: a persisted transcript is the
    /// listability test.
    ///
    /// The request runs in one server span, and it writes one "enter" record
    /// when it starts, because the tool and MCP server composition can take a
    /// long time (``RequestTracing``). The span carries the id of the new
    /// session.
    ///
    /// - Parameter params: The request: the absolute `cwd`, the ordered
    ///   `additionalDirectories`, and the client's session-scoped
    ///   `mcpServers`.
    /// - Returns: The response carrying the new sessionId, the
    ///   `availableCommands` list and the `configOptions` list.
    /// - Throws: The order rule's invalid-request error,
    ///   `RequestError.invalidParams` for a relative cwd or for a cwd or an
    ///   additional directory that is not an existing directory, or
    ///   whatever the composition pipeline throws.
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
        // The agent never makes a session directory: the check runs before
        // the composition, which would make a missing one.
        try SessionSetup.requireExistingDirectories(
            workingDirectory: workingDirectory, additionalRoots: additionalRoots)

        let composition = try await composeSession(
            workingDirectory: workingDirectory,
            additionalRoots: additionalRoots,
            clientMCPServers: params.mcpServers ?? [])

        // The session comes from the profile's standard slot, never from
        // the router. `grammar` stays absent — a plain
        // session, not a guided one — and `agentSpawn` stays nil: an agent
        // run starts from the standalone `agents` tool of the surface,
        // never from `session/new`. The budget starts automatic
        // compaction: the fractions come from the `compaction:` section and
        // the limit from the model's resolved context, never from
        // configuration. The
        // repetition detector takes the `repetition:` section. The settle
        // period is the one that the surface gave the agent runs.
        let session = residentProfile.standard.makeBudgetedSession(
            instructions: composition.instructions,
            workingDirectory: workingDirectory,
            recordingRoot: composition.transcriptRoot,
            tools: composition.surface.tools,
            compaction: composition.configuration.compaction,
            repetition: composition.configuration.repetition,
            inlineSettleGrace: composition.surface.inlineSettleGrace,
            userPresence: userPresence)

        // The `sessions.jsonl` index record is NOT written here: the
        // prompt task appends it at the first recorded activity,
        // with the title, because a session with zero prompts is not listable.
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
        sessions[activation.sessionId]?.retainedHistory.seed(from: response)
        return response
    }

    /// Mounts one made or restored Router session into the agent: the
    /// project-registry record, the command registry with
    /// its bound builtin context, the table entry with its retained
    /// history, the command-set publication, the terminal projection, and
    /// the status report of the MCP servers.
    ///
    /// - Parameters:
    ///   - session: The root Router session to mount.
    ///   - composition: What the composition pipeline built for it.
    ///   - workingDirectory: The validated session working directory.
    ///   - additionalRoots: The session's additional confinement roots,
    ///     in wire order.
    ///   - indexRecorded: Whether the `sessions.jsonl` record already
    ///     exists, so the first prompt knows whether to append it.
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
        // Register the cwd in the user-layer project registry, so a
        // cross-project browser finds this project. A replay-only session
        // has no cwd on disk, so it registers nothing.
        if !composition.isReplayOnly {
            try ProjectRegistry(directory: composition.userLayerRoot)
                .recordSessionStart(workingDirectory: workingDirectory)
        }

        let sessionId = SessionId(rawValue: session.id.description)

        // Assemble the command registry now the session exists: the six
        // builtins capture a context bound to the live
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
        // A replay-only session refuses each prompt, so it announces no
        // command, the builtins included.
        let commands = CommandRegistry(
            builtins: composition.isReplayOnly ? [] : BuiltinCommands.make(context: commandContext),
            providers: composition.commandProviders,
            workingDirectory: workingDirectory)
        await commands.load()
        commandContext.bind(
            BuiltinCommandContext.Binding(
                session: session,
                sessionId: sessionId,
                transcriptDirectory: session.recordingDirectory,
                registry: commands))

        // The first announcement of the config-option list: one select
        // over the profile's chat slots, defaulting to
        // the standard slot the session was just composed from. The
        // announced state is recorded so the divergence check compares
        // against what the client actually saw.
        let configOptions = ConfigOptions.options(
            profile: residentProfile, selectedSlot: ConfigOptions.defaultSlot)

        // The one reader of the events of the session starts before anything
        // can mail the session, so it keeps each event (elicitation-plan
        // task 1). A missing negotiation reads as "supports nothing", the
        // same rule `initialize` applies to an unparsable capabilities
        // object.
        let shellOutput = composition.surface.shellOutput
        let stateLedger = SessionStateLedger(send: boundHistorySink(for: sessionId))
        let projector = SessionProjector(
            sessionId: sessionId,
            modelName: ConfigOptions.handle(for: ConfigOptions.defaultSlot, of: residentProfile).chosen.stringValue,
            send: boundHistorySink(for: sessionId),
            shellSnapshot: { commandID in shellOutput?.snapshot(for: commandID) },
            relay: boundConnection.map { connection in
                ElicitationRelay(
                    sessionId: sessionId,
                    capabilities: negotiatedClientCapabilities
                        ?? NegotiatedClientCapabilities(reading: ClientCapabilities()),
                    connection: connection)
            },
            runCallJoins: composition.surface.runCallJoins,
            stateLedger: stateLedger)
        await projector.attach(session)

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
            userPresence: userPresence,
            stateLedger: stateLedger,
            projector: projector,
            isReplayOnly: composition.isReplayOnly,
            indexRecorded: indexRecorded,
            retainedHistory: RetainedHistory(history))
        recordActiveSessions()

        // The response announces the first command list, and each registry
        // change after it publishes the new list.
        publishAvailableCommands(from: commands, sessionId: sessionId)

        startTerminalProjection(over: composition.surface, sessionId: sessionId)

        reportMCPServerStatus(composition.surface.mcpServerOutcomes, of: sessionId)

        return SessionActivation(
            sessionId: sessionId,
            availableCommands: CommandRegistry.availableCommands(for: await commands.commands),
            configOptions: configOptions)
    }

    /// Starts the session's terminal projection: the
    /// one consumer loop over the host-owned shell output stream,
    /// posting each terminal update through the bound connection and
    /// keeping it in the retained history (``historySink(for:connection:)``).
    /// The join table of the surface (``SessionSurface/runCallJoins``) gives
    /// the wire id of each `Terminal` announce.
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
        TerminalStream.start(
            over: shellOutput, runCallJoins: surface.runCallJoins,
            send: historySink(for: sessionId, connection: connection))
    }

    /// Sends the status report of the MCP servers of a session after the
    /// response of the current `session/new` or `session/resume` request:
    /// one `_mcp_server_status` update for each outcome, in mount order
    /// (``MCPServerStatusReport``). The client knows the session id only
    /// from the response, so no update goes out before it. A resume sends a
    /// full new report, and the client replaces its list.
    ///
    /// The updates go through `post(_:in:)` directly, never through the
    /// history sink: the status is live, and the retained history and a
    /// replay never hold it. A session with no MCP server, or an agent with
    /// no bound connection, sends nothing. The deferred work keeps the
    /// connection weakly, as the agent keeps the connection (task
    /// `^173qn8n`).
    ///
    /// - Parameters:
    ///   - outcomes: The outcome of each MCP server of the session, in mount
    ///     order.
    ///   - sessionId: The session the updates belong to.
    private func reportMCPServerStatus(_ outcomes: [MCPComposition.ServerOutcome], of sessionId: SessionId) {
        guard !outcomes.isEmpty, let connection = boundConnection else {
            return
        }
        let updates = outcomes.map(MCPServerStatusReport.update(for:))
        connection.afterRespondingInCurrentInstrumentationContext { [weak connection] in
            for update in updates {
                await connection?.post(update, in: sessionId)
            }
        }
    }

    /// Makes the configuration loader of one working directory: the one
    /// place where this agent makes a `ConfigurationLoader`.
    ///
    /// Each request path that loads the configuration of a `cwd` calls it,
    /// so each load gets the same ``name``, ``userDirectory``,
    /// ``environment`` and ``transcriptLocation``. A new path that calls it
    /// cannot miss the code override of the host.
    ///
    /// - Parameter workingDirectory: The working directory whose project
    ///   layer the loader reads.
    /// - Returns: The loader.
    nonisolated func makeConfigurationLoader(workingDirectory: URL) -> ConfigurationLoader {
        ConfigurationLoader(
            name: name,
            workingDirectory: workingDirectory,
            userDirectory: userDirectory,
            environment: environment,
            transcriptLocation: transcriptLocation)
    }

    /// Resolves the per-cwd configuration one session request starts from:
    /// the config layer, the user layer root, and
    /// the recording root.
    ///
    /// - Parameter workingDirectory: The validated session working
    ///   directory.
    /// - Returns: The resolved context.
    /// - Throws: Whatever the config load throws.
    func loadSessionContext(workingDirectory: URL) throws -> LoadedSessionContext {
        let loader = makeConfigurationLoader(workingDirectory: workingDirectory)
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

    /// Runs the per-session composition pipeline: resolve
    /// the cwd config layer, assemble the instructions, then connect the
    /// MCP servers and build the tool roster through the catalog.
    ///
    /// - Parameters:
    ///   - workingDirectory: The validated session working directory.
    ///   - additionalRoots: The session's additional confinement roots,
    ///     in wire order.
    ///   - clientMCPServers: The client's session-scoped MCP servers, in
    ///     wire order.
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

    /// Composes one session over an already-resolved configuration:
    /// assemble the instructions, then connect the MCP
    /// servers and build the tool roster through the catalog.
    ///
    /// The catalog context gets ``environment``, the environment of the
    /// host, so each session tool that reads an environment value reads the
    /// value the host gave (task ^b2kb6j1). `session/new` and
    /// `session/resume` compose through this function. A model-slot switch
    /// composes nothing: the replacement session gets the tools of this
    /// composition.
    ///
    /// - Parameters:
    ///   - context: The resolved per-cwd configuration.
    ///   - workingDirectory: The validated session working directory.
    ///   - additionalRoots: The session's additional confinement roots,
    ///     in wire order.
    ///   - clientMCPServers: The client's session-scoped MCP servers, in
    ///     wire order.
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
            clientMCPServers: clientMCPServers,
            environment: environment,
            inlineSettleGrace: inlineSettleGrace,
            userPresence: userPresence)

        // One watched registry serves the preload assembly here, the
        // slash-command source below, the `skills` tool and the agent runs
        // (a standalone tool, not a Multitool capability). `watch: true`
        // is what makes its
        // `commandUpdates` non-nil.
        let skills = await ToolCatalog.makeSkillsSource(context: catalogContext)
        let instructions = try await InstructionsAssembler(
            stack: context.loader.stack, workingDirectory: workingDirectory
        ).assemble(skills: skills?.registry)

        let surface = try await ToolCatalog.sessionSurface(context: catalogContext, skills: skills)
            .appending(hostTools: hostTools)

        return SessionComposition(
            configuration: context.loaded.configuration,
            instructions: instructions.text,
            surface: surface,
            commandProviders: makeCommandProviders(surface: surface, skills: skills?.registry),
            userLayerRoot: context.userLayerRoot,
            transcriptRoot: context.transcriptRoot,
            isReplayOnly: false)
    }

    /// Assembles the registry's later sources in precedence order:
    /// the catalog's linked `SlashCommandProviding`
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

    /// Publishes each change of the session's command set:
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
    /// Vends one session with the derived auto-compaction budget (the
    /// context size comes from the model, never from configuration):
    /// `compaction` carries the fractions and the
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
    ///   - inlineSettleGrace: The settle period of the session, in seconds:
    ///     the ``SessionSurface/inlineSettleGrace`` of the mounted surface,
    ///     thus the same period that each agent run of the surface gets.
    ///   - userPresence: Whether a user can answer the questions of the
    ///     session (``RoutedACPAgent/userPresence``). `session/new` and the
    ///     model-slot switch give it; the default is Router's default.
    /// - Returns: A new session over this model, with automatic
    ///   compaction on. The compaction keeps each skill that the model
    ///   loads with `use skill` (``SkillOutputProtection``). While an
    ///   operation is pending, the session does not run a no-op tool call
    ///   (``NoOpToolCall``).
    func makeBudgetedSession(
        instructions: String,
        workingDirectory: URL,
        recordingRoot: URL,
        tools: [any FoundationModels.Tool],
        compaction: CompactionConfiguration,
        repetition: RepetitionConfiguration,
        inlineSettleGrace: TimeInterval,
        userPresence: UserPresence = .interactive
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
        let budget = TokenBudget(
            limit: contextTokens,
            trigger: compaction.trigger,
            target: compaction.target,
            hardCeiling: compaction.hardCeiling,
            toolOutputLimit: compaction.toolOutputLimit)
        return makeSession(
            configuration: SessionConfiguration(
                instructions: instructions,
                workingDirectory: workingDirectory,
                recordingRoot: recordingRoot,
                tools: tools,
                compaction: CompactionSettings(
                    budget: budget, prompt: .default, toolOutputProtection: SkillOutputProtection.rule),
                repetitionDetection: repetition.detection,
                inlineSettleGrace: inlineSettleGrace,
                isNoOpToolCall: NoOpToolCall.check,
                userPresence: userPresence))
    }

    /// Restores one recorded session with the host rules that
    /// ``makeBudgetedSession(instructions:workingDirectory:recordingRoot:tools:compaction:repetition:inlineSettleGrace:)``
    /// gives a new session. `session/resume` restores through this one door,
    /// so a restored session and a new session cannot differ.
    ///
    /// - Parameters:
    ///   - id: The id of the recorded root session.
    ///   - recordingRoot: The recording root that holds the session.
    ///   - instructions: The freshly assembled instructions, or `nil` to keep
    ///     the recorded instructions.
    ///   - tools: The tools the model can call.
    ///   - userPresence: The user presence of the client that resumes the
    ///     session now (``RoutedACPAgent/userPresence``). It is required,
    ///     never `nil`: a restore records no sidecar, so with `nil` Router
    ///     would apply the presence recorded when the session was created,
    ///     which belongs to the client of that time. The value covers the
    ///     restored root and each restored child.
    /// - Returns: The restored session and its reports, with the host rules of
    ///   ``makeBudgetedSession(instructions:workingDirectory:recordingRoot:tools:compaction:repetition:inlineSettleGrace:)``.
    /// - Throws: Whatever Router's restore throws.
    func restoreSessionWithHostChecks(
        id: ULID,
        recordingRoot: URL,
        instructions: String?,
        tools: [any FoundationModels.Tool],
        userPresence: UserPresence
    ) async throws -> RestoredSession {
        try await restoreSession(
            id: id,
            recordingRoot: recordingRoot,
            instructions: instructions,
            tools: tools,
            toolOutputProtection: SkillOutputProtection.rule,
            isNoOpToolCall: NoOpToolCall.check,
            userPresence: userPresence)
    }
}

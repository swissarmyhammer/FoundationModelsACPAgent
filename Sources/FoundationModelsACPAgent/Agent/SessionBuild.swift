import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// What the one build of a session reads
/// (``RoutedACPAgent/registerSession(_:sessionId:parent:build:)``): the parts
/// of the entry that the caller decides.
///
/// A root session takes the parts from its composition and its placement. A
/// nested session takes the parts that belong to the mounted surface from its
/// parent entry (``init(borrowingFrom:)``), and owns the rest: see
/// ``ActiveSession`` for the list.
struct SessionBuild {
    /// The merged per-cwd configuration.
    let configuration: AgentConfiguration

    /// The assembled instructions text.
    let instructions: String

    /// The session working directory.
    let workingDirectory: URL

    /// The additional confinement roots, in wire order.
    let additionalRoots: [URL]

    /// The mounted tool surface.
    let surface: SessionSurface

    /// The slash-command registry.
    let commands: CommandRegistry

    /// The model slot of the Router session.
    let selectedSlot: ModelSlot

    /// The config-option state that the client saw last.
    let announcedConfigOptions: [SessionConfigOption]

    /// The user presence of the session.
    let userPresence: UserPresence

    /// Whether the session is replay-only.
    let isReplayOnly: Bool

    /// Whether the `index.md` of the session holds its title.
    let titleRecorded: Bool

    /// The history that the retained history of the session starts from.
    let history: SessionMergeEngine

    /// The join table of the projector of the session.
    let runCallJoins: RunCallJoinTable

    /// The build of a root session: its parts come from the composition, the
    /// placement and the command registry that the mount made.
    ///
    /// - Parameters:
    ///   - composition: What the composition pipeline built for the session.
    ///   - placement: Where the session works, and its user presence.
    ///   - commands: The command registry of the session.
    ///   - selectedSlot: The model slot of the Router session.
    ///   - announcedConfigOptions: The config-option list of the first
    ///     announcement.
    ///   - titleRecorded: Whether the `index.md` already holds the title.
    ///   - history: The history that the retained history starts from.
    init(
        composition: SessionComposition,
        placement: SessionPlacement,
        commands: CommandRegistry,
        selectedSlot: ModelSlot,
        announcedConfigOptions: [SessionConfigOption],
        titleRecorded: Bool,
        history: SessionMergeEngine
    ) {
        configuration = composition.configuration
        instructions = composition.instructions
        workingDirectory = placement.workingDirectory
        additionalRoots = placement.additionalRoots
        surface = composition.surface
        self.commands = commands
        self.selectedSlot = selectedSlot
        self.announcedConfigOptions = announcedConfigOptions
        userPresence = placement.userPresence
        isReplayOnly = composition.isReplayOnly
        self.titleRecorded = titleRecorded
        self.history = history
        runCallJoins = composition.surface.runCallJoins
    }

    /// The build of a nested session: it borrows the parts of the mounted
    /// surface from its parent, and it starts with an empty history and a
    /// join table of its own. The join table is its own because the stop of
    /// the projector of the nested session closes its table, and that close
    /// must not seal the runs that the parent waits for.
    ///
    /// - Parameter parent: The entry of the parent session.
    init(borrowingFrom parent: ActiveSession) {
        configuration = parent.configuration
        instructions = parent.instructions
        workingDirectory = parent.workingDirectory
        additionalRoots = parent.additionalRoots
        surface = parent.surface
        commands = parent.commands
        selectedSlot = parent.selectedSlot
        announcedConfigOptions = parent.announcedConfigOptions
        userPresence = parent.userPresence
        isReplayOnly = parent.isReplayOnly
        // The Router owns the record of a sub-agent session, so the first
        // prompt of the agent never writes its title.
        titleRecorded = true
        history = SessionMergeEngine()
        runCallJoins = RunCallJoinTable()
    }
}

extension RoutedACPAgent {
    /// The one build of a session, for a root session and for a nested
    /// sub-agent session: the state ledger, the projector with its
    /// elicitation relay, the history sink, and the entry of the table. The
    /// projector reads the events of `session` before anything can mail it.
    ///
    /// A root session has no parent (`parent` is `nil`), and its gate is open
    /// (``SessionAnnouncementGate``). A session with a parent is linked in the
    /// ``sessionTree``, takes the owner of its parent
    /// (``ConnectionTable/owner(of:)``), and starts with a closed
    /// gate. The parts that a nested session borrows or owns are in
    /// ``ActiveSession``.
    ///
    /// The steps that belong to the mounted surface of a root session only
    /// (the record of the placement, the bind of the shell identity, the
    /// command registry, the publication of the commands, the terminal
    /// projection and the status of the MCP servers) stay with
    /// ``activateSession(_:composition:placement:titleRecorded:history:)``:
    /// a nested session borrows their results from its parent, and would
    /// otherwise do them a second time on the same surface.
    ///
    /// - Parameters:
    ///   - session: The Router session.
    ///   - sessionId: The ACP session id: the ULID of `session`.
    ///   - parent: The session that this session is nested in, or `nil`.
    ///   - build: The parts that the entry takes from the caller.
    /// - Throws: `RequestError.unknownSession` when `parent` is not in the
    ///   table, and ``SessionTreeError`` when the link is refused. A refused
    ///   build stops its projector and leaves no entry and no link.
    func registerSession(
        _ session: any RoutedSession, sessionId: SessionId, parent: SessionId?, build: SessionBuild
    ) async throws {
        let announcement = SessionAnnouncementGate(isOpen: parent == nil)
        let send = historySink(for: sessionId, gate: announcement)
        let stateLedger = SessionStateLedger(
            send: send, announce: unrecordedSink(for: sessionId, gate: announcement))
        let shellOutput = build.surface.shellOutput
        let table = connections
        let projector = SessionProjector(
            sessionId: sessionId,
            modelName: ConfigOptions.handle(for: build.selectedSlot, of: residentProfile).chosen.stringValue,
            send: send,
            shellSnapshot: { commandID in shellOutput?.snapshot(for: commandID) },
            relay: ElicitationRelay(sessionId: sessionId, stateLedger: stateLedger) { table.path(forSession: sessionId) },
            runCallJoins: build.runCallJoins,
            stateLedger: stateLedger)
        await projector.attach(session)
        // No `await` stands between the link and the entry, so the parent
        // cannot leave the table between them.
        do {
            try linkNested(sessionId, under: parent)
        } catch {
            await projector.stop()
            throw error
        }
        sessions[sessionId] = ActiveSession(
            session: session,
            configuration: build.configuration,
            instructions: build.instructions,
            workingDirectory: build.workingDirectory,
            additionalRoots: build.additionalRoots,
            transcriptDirectory: session.recordingDirectory,
            surface: build.surface,
            commands: build.commands,
            selectedSlot: build.selectedSlot,
            announcedConfigOptions: build.announcedConfigOptions,
            userPresence: build.userPresence,
            stateLedger: stateLedger,
            projector: projector,
            parentSessionId: parent,
            announcement: announcement,
            isReplayOnly: build.isReplayOnly,
            titleRecorded: build.titleRecorded,
            retainedHistory: RetainedHistory(build.history))
        if let parent {
            sessions[parent]?.children.append(sessionId)
        }
        recordActiveSessions()
    }

    /// Records the parent link of a session in the ``sessionTree``. The
    /// session then has the owner of its parent (``ConnectionTable/owner(of:)``).
    /// A root session records nothing.
    ///
    /// - Parameters:
    ///   - sessionId: The session.
    ///   - parent: The session that it is nested in, or `nil`.
    /// - Throws: `RequestError.unknownSession` when `parent` is not in the
    ///   table, and ``SessionTreeError`` when the tree refuses the link.
    private func linkNested(_ sessionId: SessionId, under parent: SessionId?) throws {
        guard let parent else {
            return
        }
        guard sessions[parent] != nil else {
            throw RequestError.unknownSession(id: parent)
        }
        try sessionTree.link(sessionId, toParent: parent)
    }

    /// Registers the Router session of a sub-agent as a session nested in
    /// `parent`. The ACP id of the nested session is the ULID of its Router
    /// session, as for a root session, and no table maps one id to another.
    ///
    /// The build is the one of a root session
    /// (``registerSession(_:sessionId:parent:build:)``), with the surface of
    /// the parent borrowed. The gate of the nested session starts closed, so
    /// nothing leaves for it before its announcement.
    ///
    /// - Parameters:
    ///   - session: The Router session of the sub-agent.
    ///   - parent: The session that started the sub-agent: a root session,
    ///     or a nested session that is in the table.
    /// - Returns: The ACP session id of the nested session.
    /// - Throws: Whatever ``registerSession(_:sessionId:parent:build:)``
    ///   throws.
    @discardableResult
    func registerNestedSession(_ session: any RoutedSession, parent: SessionId) async throws -> SessionId {
        guard let parentEntry = sessions[parent] else {
            throw RequestError.unknownSession(id: parent)
        }
        let sessionId = SessionId(rawValue: session.id.description)
        try await registerSession(
            session, sessionId: sessionId, parent: parent, build: SessionBuild(borrowingFrom: parentEntry))
        return sessionId
    }

    /// Retires a nested session: tears it down with the sessions nested in
    /// it (``tearDownSession(_:entry:)``), and removes its entry, its link and
    /// its owner. A host calls it when the run of the sub-agent closed its
    /// Router session. A session that is not nested, or that the table does
    /// not hold, is left as it is: a root session stays in the table, closed
    /// and resumable.
    ///
    /// - Parameter sessionId: The nested session.
    func retireSession(_ sessionId: SessionId) async {
        guard let entry = sessions[sessionId], let parent = entry.parentSessionId else {
            return
        }
        await tearDownSession(sessionId, entry: entry)
        sessionTree.remove(sessionId)
        sessions[parent]?.children.removeAll { $0 == sessionId }
        sessions.removeValue(forKey: sessionId)
        recordActiveSessions()
    }
}

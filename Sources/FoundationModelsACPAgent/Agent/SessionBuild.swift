import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// What the one build of a session reads
/// (``RoutedACPAgent/registerSession(_:sessionId:parent:build:events:)``): the parts
/// of the entry that the caller decides.
///
/// A root session takes the parts from its composition and its placement. A
/// nested session takes the parts of the mounted surface from its parent entry
/// (``init(borrowingFrom:)``). It owns the rest. See ``ActiveSession`` for the
/// list.
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

  /// The methods that the client can use on the session.
  let capabilities: SessionCapabilitySet

  /// The build of a root session. Its parts come from the composition, the
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
    capabilities = .all
  }

  /// The build of a nested session. It borrows the parts of the mounted
  /// surface from its parent. It starts with the history it is given, and a
  /// join table of its own. The nested session has its own join table. The stop of
  /// its projector closes that table. The close must not seal the runs that
  /// the parent waits for. The tool call ids of the nested session and of its
  /// parent never meet. Each session has its own table. The two tables share
  /// the holds on the final status of the `agents` calls
  /// (``AgentCallHolds``) and the projector of the messages between a caller and a child
  /// (``SubagentMessageProjector``). The runs of the whole surface are held in one
  /// place.
  ///
  /// - Parameters:
  ///   - parent: The entry of the parent session.
  ///   - history: The history that the retained history of the nested session
  ///     starts from. A session that starts new has none. A session that a
  ///     resume restores has the history of its file.
  init(borrowingFrom parent: ActiveSession, history: SessionMergeEngine = SessionMergeEngine()) {
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
    self.history = history
    runCallJoins = RunCallJoinTable(
      holds: parent.surface.runCallJoins.holds, messages: parent.surface.runCallJoins.messages)
    capabilities = SessionCapabilitySet(advertised: SubagentAnnouncer.childCapabilities)
  }
}

extension RoutedACPAgent {
  /// The gate that holds the updates of a nested session until the announcer opens it.
  ///
  /// The agents tool starts a nested session, so its surface has an announcer. A surface with
  /// none is an unexpected state. The session then gets a gate that discards each update.
  /// The surprise is recorded here, in the debug build and in the log of a release build.
  ///
  /// - Parameters:
  ///   - session: The Router session.
  ///   - sessionId: The ACP session id of `session`.
  ///   - parent: The session that `session` is nested in.
  ///   - build: The parts that the entry takes from the caller.
  /// - Returns: The gate of the announcer, or a gate that discards every update.
  private func nestedAnnouncementGate(
    for session: any RoutedSession, sessionId: SessionId, parent: SessionId, build: SessionBuild
  ) -> SessionAnnouncementGate {
    guard let announcer = build.surface.agents?.announcer else {
      assertionFailure("a nested session has no announcer")
      ACPAgentTelemetry.logger(.sessionLifecycle).error(
        "A nested session has no announcer; the gate discards every update of the session.",
        metadata: ACPAgentTelemetry.sessionMetadata(sessionId, parent: parent))
      return .discarded(owner: "\(session.id)")
    }
    return announcer.gate(for: session.id)
  }

  /// The one build of a session, for a root session and for a nested
  /// sub-agent session. It makes the state ledger, the projector with its
  /// elicitation relay, the history sink, and the entry of the table. The
  /// projector reads the events of `session` before anything can mail it.
  ///
  /// A root session has no parent (`parent` is `nil`), and its gate is open
  /// (``SessionAnnouncementGate``). A session with a parent is linked in the
  /// ``sessionTree``. It takes the owner of its parent
  /// (``ConnectionTable/owner(of:)``). It takes its gate from the announcer
  /// (``SubagentAnnouncer/gate(for:)``): the gate is closed until the
  /// announcement went out. The parts that a nested session borrows or owns
  /// are in ``ActiveSession``.
  ///
  /// Some steps belong to the mounted surface of a root session only. These
  /// steps are the record of the placement, the bind of the shell identity,
  /// and the command registry. They are also the publication of the
  /// commands, the terminal projection and the status of the MCP servers.
  /// They stay with
  /// ``activateSession(_:composition:placement:titleRecorded:history:)``.
  /// A nested session borrows their results from its parent. Else it would
  /// do them a second time on the same surface.
  ///
  /// - Parameters:
  ///   - session: The Router session.
  ///   - sessionId: The ACP session id: the ULID of `session`.
  ///   - parent: The session that this session is nested in, or `nil`.
  ///   - build: The parts that the entry takes from the caller.
  ///   - events: The outputs that the projector reads in place of a new
  ///     subscription to `session`, or `nil` to subscribe. The announcer
  ///     keeps the outputs of a run from its first event
  ///     (``SubagentAnnouncer/observe(_:output:)``). So the projector of a
  ///     child misses no event that the run sent before the registration.
  /// - Throws: `RequestError.unknownSession` when `parent` is not in the
  ///   table, and ``SessionTreeError`` when the link is refused. A refused
  ///   build stops its projector and leaves no entry and no link.
  func registerSession(
    _ session: any RoutedSession, sessionId: SessionId, parent: SessionId?, build: SessionBuild,
    events: AsyncStream<SessionOutput>? = nil
  ) async throws {
    // The gate is the one object that the announcer opens, and it exists
    // before the first suspension. So an announcement that goes out at any
    // time before, during or after this registration opens this gate.
    // A root session is known from its response, so its gate is open.
    let announcement: SessionAnnouncementGate
    if let parent {
      announcement = nestedAnnouncementGate(
        for: session, sessionId: sessionId, parent: parent, build: build)
    } else {
      announcement = SessionAnnouncementGate(isOpen: true)
    }
    let send = historySink(for: sessionId, gate: announcement)
    let stateLedger = SessionStateLedger(
      send: send, announce: unrecordedSink(for: sessionId, gate: announcement))
    if let parent {
      await stateLedger.observeActivity { [weak self] isActive, version in
        await self?.sessions[parent]?.stateLedger.subagentActivity(
          sessionId, isActive: isActive, version: version)
      }
    }
    let shellOutput = build.surface.shellOutput
    let table = connections
    let projector = SessionProjector(
      sessionId: sessionId,
      parentSessionId: parent,
      modelName: ConfigOptions.handle(for: build.selectedSlot, of: residentProfile).chosen
        .stringValue,
      send: send,
      shellSnapshot: { commandID in shellOutput?.snapshot(for: commandID) },
      relay: ElicitationRelay(
        sessionId: sessionId, parentSessionId: parent, stateLedger: stateLedger,
        announcement: announcement,
        claims: elicitationClaims,
        outboundPath: { table.path(forSession: sessionId) }),
      runCallJoins: build.runCallJoins,
      stateLedger: stateLedger)
    if let events {
      await projector.attach(
        events, from: SessionProjector.Source(id: session.id, session: session))
    } else {
      await projector.attach(session)
    }
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
      capabilities: build.capabilities,
      isReplayOnly: build.isReplayOnly,
      titleRecorded: build.titleRecorded,
      retainedHistory: RetainedHistory(build.history))
    if let parent {
      sessions[parent]?.children.append(sessionId)
    }
    recordActiveSessions()
    // A new entry can unblock an announcement that waited for it.
    build.surface.agents?.announcer.retryBlocked()
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
  /// session, as for a root session. No table maps one id to another.
  ///
  /// The build is the one of a root session
  /// (``registerSession(_:sessionId:parent:build:events:)``), with the surface of
  /// the parent borrowed. The gate of the nested session starts closed. So
  /// nothing leaves for it before its announcement, unless the announcement went
  /// out already.
  ///
  /// - Parameters:
  ///   - session: The Router session of the sub-agent.
  ///   - parent: The session that started the sub-agent: a root session,
  ///     or a nested session that is in the table.
  ///   - events: The outputs that the projector reads, or `nil` to
  ///     subscribe to `session` (``registerSession(_:sessionId:parent:build:events:)``).
  ///   - history: The history that the retained history of the nested session
  ///     starts from. It is empty for a new run.
  /// - Returns: The ACP session id of the nested session.
  /// - Throws: Whatever ``registerSession(_:sessionId:parent:build:events:)``
  ///   throws.
  @discardableResult
  func registerNestedSession(
    _ session: any RoutedSession, parent: SessionId, events: AsyncStream<SessionOutput>? = nil,
    history: SessionMergeEngine = SessionMergeEngine()
  ) async throws -> SessionId {
    guard let parentEntry = sessions[parent] else {
      throw RequestError.unknownSession(id: parent)
    }
    let sessionId = SessionId(rawValue: session.id.description)
    // The key goes in before the registration, so the `snapshots` tool of the child reads it
    // before the first submission of the child.
    SnapshotSessionKeys.shared.record(
      snapshotKey(ofNestedIn: parent, entry: parentEntry), for: sessionId)
    do {
      try await registerSession(
        session, sessionId: sessionId, parent: parent,
        build: SessionBuild(borrowingFrom: parentEntry, history: history),
        events: events)
    } catch {
      SnapshotSessionKeys.shared.forget(sessionId)
      throw error
    }
    return sessionId
  }

  /// The snapshot key of a session nested in `parent`: the key of its parent, so a child shares
  /// the one timeline of its folder with its root. The Router gives the hooks of the child the
  /// same key. A parent with no recorded key gives the key of its working directory, which is
  /// the key that the hooks of a root session have.
  ///
  /// - Parameters:
  ///   - parent: The parent session.
  ///   - entry: The entry of the parent in the table.
  /// - Returns: The snapshot key of the child.
  private func snapshotKey(ofNestedIn parent: SessionId, entry: ActiveSession) -> String {
    SnapshotSessionKeys.shared.sessionKey(of: parent.rawValue)
      ?? AgentHome.projectKey(of: entry.workingDirectory)
  }

  /// Retires a nested session. It tears the session down with the sessions
  /// nested in it (``tearDownSession(_:entry:)``). It also removes its entry,
  /// its link and its owner. A host calls it when the run of the sub-agent
  /// closed its Router session. A session that is not nested is left as it
  /// is. A session that the table does not hold is left as it is too. A root
  /// session stays in the table, closed and resumable.
  ///
  /// - Parameter sessionId: The nested session.
  func retireSession(_ sessionId: SessionId) async {
    guard let entry = sessions[sessionId], let parent = entry.parentSessionId else {
      return
    }
    await tearDownSession(sessionId, entry: entry)
    // The child sent its last updates, so the list of the parent can drop it.
    await sessions[parent]?.stateLedger.subagentRetired(sessionId)
    // The snapshot timeline belongs to the folder, and the child leaves it as it was. Only the
    // key of the child session goes.
    SnapshotSessionKeys.shared.forget(sessionId)
    sessionTree.remove(sessionId)
    sessions[parent]?.children.removeAll { $0 == sessionId }
    sessions.removeValue(forKey: sessionId)
    recordActiveSessions()
  }
}

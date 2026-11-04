import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsMultitool
import Synchronization
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The background list of the `state_update` snapshots (ACP v2 "Background Work"). The book keeps
/// the list. An item is listed only after its announcement, and it leaves only after its final
/// status. The state ledger puts the list on every `state_update`, and it sends the state again
/// when the list changes.
@Suite struct BackgroundListTests {
  // MARK: - Readers

  /// The wire id of the tool call that the tests use.
  static let call = ToolCallId(rawValue: "call-1")

  /// The wire id of the terminal that the tests use.
  static let terminal = TerminalId(rawValue: "terminal-1")

  /// The id of the child session that the tests use.
  static let child = SessionId(rawValue: "child-1")

  /// The list entry of the tool call of the tests.
  static let callEntry = callEntry(call.rawValue)

  /// The list entry of a tool call.
  ///
  /// - Parameter id: The wire id of the call.
  /// - Returns: The entry.
  static func callEntry(_ id: String) -> FoundationModelsACP.BackgroundWork {
    .toolCall(BackgroundToolCall(toolCallId: ToolCallId(rawValue: id)))
  }

  /// The list entry of the terminal of the tests.
  static let terminalEntry = FoundationModelsACP.BackgroundWork.terminal(
    BackgroundTerminal(terminalId: terminal))

  /// The list entry of the child of the tests.
  static let childEntry = FoundationModelsACP.BackgroundWork.subagent(
    BackgroundSubagent(sessionId: child))

  /// The background list of a `state_update`.
  ///
  /// - Parameter update: The update.
  /// - Returns: The list, or `nil` when the update is no state update or reports no list.
  static func list(of update: SessionUpdate?) -> [FoundationModelsACP.BackgroundWork]? {
    guard case .stateUpdate(let state)? = update else {
      return nil
    }
    switch state {
    case .running(let running):
      return running.background
    case .idle(let idle):
      return idle.background
    case .requiresAction(let action):
      return action.background
    case .unknown:
      return nil
    }
  }

  /// The lists of the `state_update` items in a sequence, in order.
  ///
  /// - Parameter updates: The sent updates.
  /// - Returns: One entry for each state update.
  static func lists(of updates: [SessionUpdate]) -> [[FoundationModelsACP.BackgroundWork]?] {
    updates.filter { stateNames(of: [$0]).count == 1 }.map { list(of: $0) }
  }

  /// The book after some changes.
  ///
  /// - Parameter changes: The changes, in order.
  /// - Returns: The book.
  static func book(after changes: [BackgroundChange]) -> BackgroundBook {
    var book = BackgroundBook()
    for change in changes {
      book.apply(change)
    }
    return book
  }

  // MARK: - The book

  /// The book lists a call after the announcement and the detach, in any order.
  @Suite struct Book {
    @Test func aDetachedCallIsNotListedBeforeItIsAnnounced() {
      let book = BackgroundListTests.book(after: [.callDetached(BackgroundListTests.call)])

      #expect(book.list == [])
    }

    @Test func aDetachedCallIsListedAfterItIsAnnounced() {
      let book = BackgroundListTests.book(after: [
        .callAnnounced(BackgroundListTests.call), .callDetached(BackgroundListTests.call),
      ])

      #expect(book.list == [BackgroundListTests.callEntry])
    }

    @Test func anAnnouncementAfterTheDetachListsTheCall() {
      let book = BackgroundListTests.book(after: [
        .callDetached(BackgroundListTests.call), .callAnnounced(BackgroundListTests.call),
      ])

      #expect(book.list == [BackgroundListTests.callEntry])
    }

    @Test func anAnnouncedCallThatDoesNotDetachIsNotListed() {
      let book = BackgroundListTests.book(after: [.callAnnounced(BackgroundListTests.call)])

      #expect(book.list == [])
    }

    @Test func aSettledCallLeavesTheList() {
      let book = BackgroundListTests.book(after: [
        .callAnnounced(BackgroundListTests.call), .callDetached(BackgroundListTests.call),
        .callSettled(BackgroundListTests.call),
      ])

      #expect(book.list == [])
    }

    @Test func aTerminalIsListedInPlaceOfItsCall() {
      let book = BackgroundListTests.book(after: [
        .callDetached(BackgroundListTests.call),
        .terminalAnnounced(BackgroundListTests.terminal, on: BackgroundListTests.call),
      ])

      #expect(book.list == [BackgroundListTests.terminalEntry])
    }

    @Test func anExitedTerminalLeavesItsCallListed() {
      let book = BackgroundListTests.book(after: [
        .callDetached(BackgroundListTests.call),
        .terminalAnnounced(BackgroundListTests.terminal, on: BackgroundListTests.call),
        .terminalExited(BackgroundListTests.terminal),
      ])

      #expect(book.list == [BackgroundListTests.callEntry])
    }

    @Test func aTerminalOfACallThatDoesNotDetachIsNotListed() {
      let book = BackgroundListTests.book(after: [
        .terminalAnnounced(BackgroundListTests.terminal, on: BackgroundListTests.call)
      ])

      #expect(book.list == [])
    }

    @Test func aSettledCallTakesItsTerminalOffTheList() {
      let book = BackgroundListTests.book(after: [
        .callDetached(BackgroundListTests.call),
        .terminalAnnounced(BackgroundListTests.terminal, on: BackgroundListTests.call),
        .callSettled(BackgroundListTests.call),
      ])

      #expect(book.list == [])
    }
  }

  /// The book lists a child only when the parent announced it and it is active.
  @Suite struct Children {
    @Test func anActiveChildIsNotListedBeforeItIsAnnounced() {
      let book = BackgroundListTests.book(after: [
        .subagentActivity(BackgroundListTests.child, isActive: true)
      ])

      #expect(book.list == [])
    }

    @Test func anAnnouncedActiveChildIsListed() {
      let book = BackgroundListTests.book(after: [
        .subagentActivity(BackgroundListTests.child, isActive: true),
        .subagentAnnounced(BackgroundListTests.child),
      ])

      #expect(book.list == [BackgroundListTests.childEntry])
    }

    @Test func anAnnouncedIdleChildIsNotListed() {
      let book = BackgroundListTests.book(after: [
        .subagentAnnounced(BackgroundListTests.child),
        .subagentActivity(BackgroundListTests.child, isActive: false),
      ])

      #expect(book.list == [])
    }

    @Test func aChildThatBecomesIdleLeavesTheList() {
      let book = BackgroundListTests.book(after: [
        .subagentAnnounced(BackgroundListTests.child),
        .subagentActivity(BackgroundListTests.child, isActive: true),
        .subagentActivity(BackgroundListTests.child, isActive: false),
      ])

      #expect(book.list == [])
    }

    @Test func aRetiredChildLeavesTheList() {
      let book = BackgroundListTests.book(after: [
        .subagentAnnounced(BackgroundListTests.child),
        .subagentActivity(BackgroundListTests.child, isActive: true),
        .subagentRetired(BackgroundListTests.child),
      ])

      #expect(book.list == [])
    }
  }

  // MARK: - The ledger

  /// The state ledger puts the list on every `state_update`, and sends the state again when the
  /// list changes.
  @Suite struct Ledger {
    /// A ledger that sends every update to one sink.
    ///
    /// - Returns: The ledger and its sink.
    private static func makeLedger() -> (ledger: SessionStateLedger, sink: RecordingSink) {
      let sink = RecordingSink()
      return (SessionStateLedger(send: sink.send), sink)
    }

    /// A running ledger with one detached call that the client knows.
    ///
    /// - Returns: The ledger and its sink.
    private static func makeLedgerWithADetachedCall() async -> (
      ledger: SessionStateLedger, sink: RecordingSink
    ) {
      let parts = makeLedger()
      await parts.ledger.promptStarted()
      await parts.ledger.background(.callAnnounced(BackgroundListTests.call))
      await parts.ledger.background(.callDetached(BackgroundListTests.call))
      return parts
    }

    @Test func aStateChangeCarriesAnEmptyListWhenNothingRunsApart() async {
      let parts = Self.makeLedger()

      await parts.ledger.promptStarted()

      #expect(BackgroundListTests.lists(of: parts.sink.updates) == [[]])
    }

    @Test func theSnapshotCarriesAnEmptyListWhenNothingRunsApart() async {
      let parts = Self.makeLedger()

      await parts.ledger.announceCurrentState()

      #expect(BackgroundListTests.lists(of: parts.sink.updates) == [[]])
    }

    @Test func aNewListSendsTheStateAgainWithTheList() async {
      let parts = await Self.makeLedgerWithADetachedCall()

      #expect(
        BackgroundListTests.lists(of: parts.sink.updates) == [[], [BackgroundListTests.callEntry]])
    }

    @Test func aSettledCallSendsTheStateAgainWithoutTheCall() async {
      let parts = await Self.makeLedgerWithADetachedCall()

      await parts.ledger.background(.callSettled(BackgroundListTests.call))

      #expect(BackgroundListTests.lists(of: parts.sink.updates).last == [])
    }

    @Test func anUnchangedListSendsNothing() async {
      let parts = await Self.makeLedgerWithADetachedCall()
      let sentBefore = parts.sink.updates.count

      await parts.ledger.background(.callAnnounced(BackgroundListTests.call))

      #expect(parts.sink.updates.count == sentBefore)
    }

    @Test func aNewListGoesToTheSinkThatRecordsNothingInTheHistory() async {
      let changes = RecordingSink()
      let ledger = SessionStateLedger(send: changes.send, announce: RecordingSink().send)
      await ledger.promptStarted()

      await ledger.background(.callAnnounced(BackgroundListTests.call))
      await ledger.background(.callDetached(BackgroundListTests.call))

      #expect(changes.updates.count == 1)
    }

    @Test func theSnapshotCarriesTheListThatRunsNow() async {
      let parts = await Self.makeLedgerWithADetachedCall()

      await parts.ledger.announceCurrentState()

      #expect(
        BackgroundListTests.lists(of: parts.sink.updates).last == [BackgroundListTests.callEntry])
    }
  }

  // MARK: - The activity of a child

  /// A child ledger tells its observer when the child starts or stops to work. The parent ledger
  /// lists the child while it works.
  @Suite struct Activity {
    /// A running parent ledger that knows the child.
    ///
    /// - Returns: The ledger and its sink.
    private static func makeParentOfAnAnnouncedChild() async -> (
      ledger: SessionStateLedger, sink: RecordingSink
    ) {
      let sink = RecordingSink()
      let ledger = SessionStateLedger(send: sink.send)
      await ledger.promptStarted()
      await ledger.subagentAnnounced(BackgroundListTests.child)
      return (ledger, sink)
    }

    @Test func aSessionTellsItsObserverAfterItsRunningStateWentOut() async {
      let log = Mutex<[String]>([])
      let ledger = SessionStateLedger(send: { _ in log.withLock { $0.append("sent") } })
      await ledger.observeActivity { isActive, _ in log.withLock { $0.append("active:\(isActive)") }
      }

      await ledger.promptStarted()

      #expect(log.withLock { $0 } == ["sent", "active:true"])
    }

    @Test func aSessionTellsItsObserverAfterItsIdleStateWentOut() async {
      let log = Mutex<[String]>([])
      let ledger = SessionStateLedger(send: { _ in log.withLock { $0.append("sent") } })
      await ledger.promptStarted()
      log.withLock { $0.removeAll() }
      await ledger.observeActivity { isActive, _ in log.withLock { $0.append("active:\(isActive)") }
      }

      await ledger.promptEnded(IdleStateUpdate(), started: true)

      #expect(log.withLock { $0 } == ["sent", "active:false"])
    }

    @Test func aSessionTellsItsObserverNothingWhenItsActivityDoesNotChange() async {
      let log = Mutex<[String]>([])
      let ledger = SessionStateLedger(send: { _ in })
      await ledger.promptStarted()
      await ledger.observeActivity { isActive, _ in log.withLock { $0.append("active:\(isActive)") }
      }

      await ledger.promptStarted()

      #expect(log.withLock { $0 } == [])
    }

    @Test func aSessionWithRunWorkApartIsActiveWhileItIsIdle() async {
      let log = Mutex<[String]>([])
      let ledger = SessionStateLedger(send: { _ in })
      await ledger.observeActivity { isActive, _ in log.withLock { $0.append("active:\(isActive)") }
      }

      await ledger.background(.callAnnounced(BackgroundListTests.call))
      await ledger.background(.callDetached(BackgroundListTests.call))

      #expect(log.withLock { $0 } == ["active:true"])
    }

    @Test func aParentListsAnAnnouncedChildThatWorks() async {
      let parts = await Self.makeParentOfAnAnnouncedChild()

      await parts.ledger.subagentActivity(BackgroundListTests.child, isActive: true, version: 1)

      #expect(
        BackgroundListTests.lists(of: parts.sink.updates).last == [BackgroundListTests.childEntry])
    }

    @Test func aParentDropsTheChildWhenItIsIdleAgain() async {
      let parts = await Self.makeParentOfAnAnnouncedChild()
      await parts.ledger.subagentActivity(BackgroundListTests.child, isActive: true, version: 1)

      await parts.ledger.subagentActivity(BackgroundListTests.child, isActive: false, version: 2)

      #expect(BackgroundListTests.lists(of: parts.sink.updates).last == [])
    }

    @Test func aParentTakesNoReportThatIsOlderThanTheLastOne() async {
      let parts = await Self.makeParentOfAnAnnouncedChild()
      await parts.ledger.subagentActivity(BackgroundListTests.child, isActive: true, version: 2)

      await parts.ledger.subagentActivity(BackgroundListTests.child, isActive: false, version: 1)

      #expect(
        BackgroundListTests.lists(of: parts.sink.updates).last == [BackgroundListTests.childEntry])
    }

    @Test func aParentDoesNotListAChildBeforeItsAnnouncement() async {
      let sink = RecordingSink()
      let ledger = SessionStateLedger(send: sink.send)
      await ledger.promptStarted()

      await ledger.subagentActivity(BackgroundListTests.child, isActive: true, version: 1)

      #expect(BackgroundListTests.lists(of: sink.updates) == [[]])
    }

    @Test func aParentDropsARetiredChild() async {
      let parts = await Self.makeParentOfAnAnnouncedChild()
      await parts.ledger.subagentActivity(BackgroundListTests.child, isActive: true, version: 1)

      await parts.ledger.subagentRetired(BackgroundListTests.child)

      #expect(BackgroundListTests.lists(of: parts.sink.updates).last == [])
    }
  }

  // MARK: - The resume sync

  /// The resume sync sends the current update of each listed item before the snapshot that lists
  /// it. A replay sends them already, so then the sync sends the snapshot alone.
  @Suite(.closesHarnesses, .timeLimit(.minutes(1))) struct Resume {
    /// The kind of an update, as the order tests read it.
    private enum Kind: Equatable {
      /// A `tool_call_update` of the listed call.
      case call

      /// A `state_update` that lists the call.
      case listingState

      /// Another update.
      case other
    }

    /// The kind of an update.
    ///
    /// - Parameter update: The update.
    /// - Returns: The kind.
    private static func kind(of update: SessionUpdate) -> Kind {
      if case .toolCallUpdate(let held) = update, held.toolCallId == BackgroundListTests.call {
        return .call
      }
      if BackgroundListTests.list(of: update) == [BackgroundListTests.callEntry] {
        return .listingState
      }
      return .other
    }

    /// A session with one detached call that the history holds. The change of the list reached the
    /// client already.
    ///
    /// - Returns: The fixture of the session.
    /// - Throws: Whatever the setup throws.
    private static func makeSessionWithAListedCall() async throws -> ResumeSessionFixture {
      let resume = try await ResumeSessionFixture.make(label: "BackgroundListTests-resume")
      let agent = resume.fixture.harness.agent
      let sessionId = resume.fixture.sessionId
      let ledger = try #require(await agent.sessions[sessionId]?.stateLedger)
      await agent.recordInHistory(
        .toolCallUpdate(
          ToolCallUpdate(
            toolCallId: BackgroundListTests.call, name: .value("shell"),
            status: .value(.inProgress))),
        of: sessionId)
      await ledger.background(.callAnnounced(BackgroundListTests.call))
      await ledger.background(.callDetached(BackgroundListTests.call))
      _ = try await resume.fixture.collector.wait(for: "the live change of the list") { updates in
        updates.contains { Self.kind(of: $0.update) == .listingState }
      }
      return resume
    }

    /// Runs the sync and gives what it sent.
    ///
    /// - Parameters:
    ///   - resume: The fixture of the session.
    ///   - replayed: Whether the resume replayed the history.
    ///   - count: The number of updates the sync sends.
    /// - Returns: The kinds of the updates of the sync, in order.
    /// - Throws: Whatever the wait throws.
    private static func syncKinds(of resume: ResumeSessionFixture, replayed: Bool, count: Int)
      async throws -> [Kind]
    {
      let countBefore = await resume.fixture.collector.updates.count
      await resume.fixture.harness.agent.syncCurrentState(
        of: resume.fixture.sessionId, replayed: replayed)
      let received = try await resume.fixture.collector.wait(for: "the sync reaches the client") {
        $0.count >= countBefore + count
      }
      return received.dropFirst(countBefore).map { Self.kind(of: $0.update) }
    }

    @Test func theItemUpdateComesBeforeTheSnapshotThatListsIt() async throws {
      let resume = try await Self.makeSessionWithAListedCall()

      let kinds = try await Self.syncKinds(of: resume, replayed: false, count: 2)
      await resume.fixture.close()

      #expect(kinds == [.call, .listingState])
    }

    @Test func aReplayAlreadySentTheItemSoTheSyncSendsTheSnapshotAlone() async throws {
      let resume = try await Self.makeSessionWithAListedCall()

      let kinds = try await Self.syncKinds(of: resume, replayed: true, count: 1)
      await resume.fixture.close()

      #expect(kinds == [.listingState])
    }
  }

  // MARK: - The running children

  /// The root session lists a running child after the `subagent_update` of the child. It drops
  /// the child after the last update of the child.
  @Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct RunningChildren {
    /// The prefix of the folders of each fixture of this suite.
    private static let label = "BackgroundListTests-children"

    /// A fixture with an agent whose run holds after its first text.
    ///
    /// - Parameter hold: The hold that the run waits on.
    /// - Returns: The fixture.
    /// - Throws: Whatever the fixture throws.
    private static func makeFixture(hold: ScriptedHold) async throws -> ScriptedPromptFixture {
      let cwd = makeResolvedDirectory(label: "\(label)-repo")
      try AgentsToolTests.writeAgent(named: AgentsToolTests.slowAgent, in: cwd)
      let script: [ScriptedPassStep] = [
        .onPrompt(
          containing: AgentsToolTests.slowRunPrompt,
          play: [
            .textDelta("STARTED"), .holdUntilReleased(hold),
            .textDelta(AgentsToolTests.slowFinalText), .endPass,
          ]),
        .endPass,
      ]
      return try await ScriptedPromptFixture.make(
        script: script, label: label, workingDirectory: cwd, runClock: ManualRunClock())
    }

    /// Starts the run of the held agent.
    ///
    /// - Parameter fixture: The fixture.
    /// - Returns: The ACP id of the child.
    /// - Throws: Whatever the start throws.
    private static func startRun(in fixture: ScriptedPromptFixture) async throws -> SessionId {
      let agents = try #require(
        await fixture.harness.agent.sessions[fixture.sessionId]?.surface.agents)
      let run = try await agents.runner.start(
        AgentsToolTests.slowAgent, prompt: AgentsToolTests.slowRunPrompt)
      return SessionId(rawValue: run.id.description)
    }

    /// Whether a notification is a state of `session` that lists `child`.
    private static func lists(_ child: SessionId, in notification: UpdateSessionNotification)
      -> Bool
    {
      BackgroundListTests.list(of: notification.update)?.contains(
        .subagent(BackgroundSubagent(sessionId: child))) ?? false
    }

    /// The position of the first notification that matches.
    private static func position(
      in updates: [UpdateSessionNotification], where matches: (UpdateSessionNotification) -> Bool
    ) -> Int? {
      updates.firstIndex(where: matches)
    }

    @Test func aRunningChildIsListedOnlyAfterItsAnnouncement() async throws {
      let hold = ScriptedHold()
      let fixture = try await Self.makeFixture(hold: hold)
      let child = try await Self.startRun(in: fixture)

      let updates = try await fixture.collector.wait(for: "the list names the child") {
        $0.contains { Self.lists(child, in: $0) }
      }
      hold.release()
      await fixture.close()

      let announced = try #require(
        Self.position(in: updates) { notification in
          if case .subagentUpdate(let update) = notification.update {
            return update.sessionId == child
          }
          return false
        })
      let listed = try #require(Self.position(in: updates) { Self.lists(child, in: $0) })
      #expect(announced < listed)
    }

    @Test func aChildLeavesTheListAfterItsLastIdle() async throws {
      let hold = ScriptedHold()
      let fixture = try await Self.makeFixture(hold: hold)
      let child = try await Self.startRun(in: fixture)
      _ = try await fixture.collector.wait(for: "the list names the child") {
        $0.contains { Self.lists(child, in: $0) }
      }

      hold.release()
      let updates = try await fixture.collector.wait(for: "the list drops the child") { updates in
        guard let listed = updates.lastIndex(where: { Self.lists(child, in: $0) }) else {
          return false
        }
        return updates.dropFirst(listed + 1).contains {
          $0.sessionId == fixture.sessionId && BackgroundListTests.list(of: $0.update) == []
        }
      }
      await fixture.close()

      let listed = try #require(updates.lastIndex { Self.lists(child, in: $0) })
      let dropped = try #require(
        updates.indices.first { index in
          index > listed && updates[index].sessionId == fixture.sessionId
            && BackgroundListTests.list(of: updates[index].update) == []
        })
      let childIdle = try #require(
        updates.firstIndex { $0.sessionId == child && isIdleState($0.update) })
      #expect(childIdle < dropped)
    }
  }

  // MARK: - A real stream

  /// A real Router stream of a background run whose call returned: the list names the call after
  /// the call returned, and it drops the call after the run settled.
  @Suite struct RealStream {
    /// The prompt that starts the run.
    private static let prompt = RoutedPrompt.defaultPrompt

    /// The updates of a prompt that calls a tool that fails later, on its own run.
    ///
    /// - Returns: The sent updates, in order.
    /// - Throws: Whatever the prompt throws.
    private static func updatesOfALateRun() async throws -> [SessionUpdate] {
      let release = WatchedValue(false)
      let script: [ScriptedPassStep] = [
        .onPrompt(
          containing: prompt,
          play: [
            .toolCall(
              name: SettledRunStatusProjectionTests.LateFailingTool.toolName, argumentsJSON: "{}")
          ]),
        .textDelta("done"),
        .endPass,
      ]
      return try await RoutedPrompt.sentUpdates(
        prompt: prompt, script: script,
        tools: [SettledRunStatusProjectionTests.LateFailingTool(release: release)],
        label: "BackgroundListTests-real", reportsBackground: true
      ) { update in
        // The run fails only after the client got the list that names it.
        if BackgroundListTests.list(of: update)?.isEmpty == false {
          release.update { $0 = true }
        }
      }
    }

    @Test func theListNamesTheCallWhileTheRunGoesOn() async throws {
      let updates = try await Self.updatesOfALateRun()

      #expect(
        BackgroundListTests.lists(of: updates).contains {
          $0?.contains { if case .toolCall = $0 { true } else { false } } ?? false
        })
    }

    @Test func theListIsEmptyAfterTheRunSettled() async throws {
      let updates = try await Self.updatesOfALateRun()

      #expect(BackgroundListTests.lists(of: updates).last == [])
    }
  }

  // MARK: - The projection

  /// The projector tells the ledger about a run that goes on after its SDK call returned. The
  /// call is announced before the list names it, and its final status goes out before the list
  /// drops it.
  @Suite struct Projection {
    /// The completion token of the run of the tests.
    private static let token = "01TOKENTOKENTOKENTOKEN0001"

    /// The SDK id of the call of the run of the tests.
    private static let sdkId = "sdk-call-1"

    /// The tool of the run of the tests.
    private static let tool = "shell"

    /// The op of the run of the tests.
    private static let op = "execute command"

    /// The events of a run that starts, posts progress, and whose call returns.
    private static var runningRun: [SessionEvent] {
      [
        .workStarted, open, progress,
        .toolCall(id: sdkId, name: tool, argumentsJSON: "{}"),
        .toolStatus(id: sdkId, status: .completed, summary: nil, output: nil),
      ]
    }

    /// The open record of the run, joined to its SDK call.
    private static var open: SessionEvent {
      .toolInvocation(
        ToolInvocationRecord(
          tool: tool, op: op, correlationID: token, sessionID: ULID.generate(), openedAt: Date()),
        toolCallID: sdkId)
    }

    /// The first progress of the run.
    private static var progress: SessionEvent {
      .runProgress(
        OperationEvent(
          tool: tool, op: op, correlationID: token, kind: .progress, detail: "started"))
    }

    /// The settlement of the run.
    private static var settlement: SessionEvent {
      .runSettled(
        OperationEvent(
          tool: tool, op: op, correlationID: token, kind: .completed, detail: "",
          outcome: .succeeded))
    }

    /// Drives the events through a projector over a state ledger, and gives what went out.
    ///
    /// - Parameter events: The events, in order.
    /// - Returns: Every update that the ledger and the projector sent, in order.
    private static func updates(driving events: [SessionEvent]) async -> [SessionUpdate] {
      let sink = RecordingSink()
      let ledger = SessionStateLedger(send: sink.send)
      let projector = SessionProjector(
        sessionId: SessionId(rawValue: syntheticSessionIdValue), modelName: syntheticModelName,
        send: sink.send, relay: nil, runCallJoins: RunCallJoinTable(), stateLedger: ledger)
      let (outputs, input) = AsyncStream.makeStream(of: SessionOutput.self)
      let source = SessionProjector.Source(id: ULID.generate(), session: nil)
      await projector.attach(outputs, from: source)
      for event in events {
        input.yield(SessionOutput(origin: .system, event: event))
      }
      input.finish()
      await projector.stop(after: [source.id])
      return sink.updates
    }

    /// The position of the first update that matches.
    ///
    /// - Parameters:
    ///   - updates: The sent updates.
    ///   - matches: Tells whether an update is the one.
    /// - Returns: The position, or `nil`.
    private static func position(
      in updates: [SessionUpdate], where matches: (SessionUpdate) -> Bool
    ) -> Int? {
      updates.firstIndex(where: matches)
    }

    /// The position of the first state update after the last list that names the call. The list
    /// of that update is empty: it drops the call.
    ///
    /// - Parameter updates: The sent updates.
    /// - Returns: The position, or `nil`.
    private static func positionOfTheDrop(in updates: [SessionUpdate]) -> Int? {
      guard let listed = updates.lastIndex(where: listsTheCall) else {
        return nil
      }
      return updates.indices.first { index in
        index > listed && updates[index].isStateUpdate
          && BackgroundListTests.list(of: updates[index]) == []
      }
    }

    /// Whether an update is a state that lists the call.
    private static func listsTheCall(_ update: SessionUpdate) -> Bool {
      BackgroundListTests.list(of: update) == [BackgroundListTests.callEntry(sdkId)]
    }

    /// Whether an update is an update of the call.
    private static func isUpdateOfTheCall(_ update: SessionUpdate) -> Bool {
      guard case .toolCallUpdate(let call) = update else {
        return false
      }
      return call.toolCallId.rawValue == sdkId
    }

    @Test func aRunWhoseCallReturnedIsListed() async {
      let updates = await Self.updates(driving: Self.runningRun)

      #expect(updates.contains(where: Self.listsTheCall))
    }

    @Test func theCallIsAnnouncedBeforeTheListNamesIt() async throws {
      let updates = await Self.updates(driving: Self.runningRun)

      let listed = try #require(Self.position(in: updates, where: Self.listsTheCall))
      let announced = try #require(Self.position(in: updates, where: Self.isUpdateOfTheCall))
      #expect(announced < listed)
    }

    @Test func aRunWithoutProgressIsNotListed() async {
      let events = Self.runningRun.filter { $0 != Self.progress }

      let updates = await Self.updates(driving: events)

      #expect(!updates.contains(where: Self.listsTheCall))
    }

    @Test func aRunThatSettledBeforeItsCallReturnedIsNotListed() async {
      let events: [SessionEvent] = [
        .workStarted, Self.open, Self.progress, Self.settlement,
        .toolCall(id: Self.sdkId, name: Self.tool, argumentsJSON: "{}"),
        .toolStatus(id: Self.sdkId, status: .completed, summary: nil, output: nil),
      ]

      let updates = await Self.updates(driving: events)

      #expect(!updates.contains(where: Self.listsTheCall))
    }

    @Test func theFinalStatusGoesOutBeforeTheListDropsTheCall() async throws {
      let updates = await Self.updates(driving: Self.runningRun + [Self.settlement])

      let final = try #require(updates.lastIndex(where: Self.isUpdateOfTheCall))
      let dropped = try #require(Self.positionOfTheDrop(in: updates))
      #expect(final < dropped)
    }

    @Test func aSettledRunLeavesNoCallOnTheLastState() async {
      let updates = await Self.updates(driving: Self.runningRun + [Self.settlement, .workEnded])

      #expect(BackgroundListTests.lists(of: updates).last == [])
    }
  }

  // MARK: - The terminal stream

  /// The terminal stream tells the ledger about the terminal of a run. It tells after the wire
  /// update of the announce, and again after the wire update of the exit.
  @Suite struct Terminals {
    /// The completion token of the run, which is also its terminal id and its wire call id.
    private static let commandID = "01SHELLRUNSHELLRUNSHELL001"

    /// What happened, in order: a sent update or a reported change.
    private enum Step: Equatable {
      /// An announce of the call, with the `Terminal` reference.
      case announceSent

      /// The exit status update of the terminal.
      case exitSent

      /// The terminal stream reported the announce of the terminal.
      case announceReported

      /// The terminal stream reported the exit of the terminal.
      case exitReported
    }

    /// Projects the events of one run, and gives the steps in order.
    ///
    /// - Parameter kinds: The kinds of the events of the run.
    /// - Returns: The steps.
    private static func steps(projecting kinds: [ShellOutputEvent.Kind]) async -> [Step] {
      let log = Mutex<[Step]>([])
      var projection = TerminalStream(snapshot: { _ in nil }) { update in
        switch update {
        case .toolCallUpdate:
          log.withLock { $0.append(.announceSent) }
        case .terminalUpdate:
          log.withLock { $0.append(.exitSent) }
        default:
          break
        }
      }
      projection.background = { change in
        switch change {
        case .terminalAnnounced:
          log.withLock { $0.append(.announceReported) }
        case .terminalExited:
          log.withLock { $0.append(.exitReported) }
        default:
          break
        }
      }
      for kind in kinds {
        await projection.project(ShellOutputEvent(commandID: commandID, kind: kind))
      }
      return log.withLock { $0 }
    }

    @Test func theAnnounceIsReportedAfterItIsSent() async {
      let steps = await Self.steps(projecting: [.output(stream: .stdout, bytes: [0x61])])

      #expect(steps == [.announceSent, .announceReported])
    }

    @Test func theExitIsReportedAfterItIsSent() async {
      let steps = await Self.steps(projecting: [.completed])

      #expect(steps == [.announceSent, .announceReported, .exitSent, .exitReported])
    }
  }
}

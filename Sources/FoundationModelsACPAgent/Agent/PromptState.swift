import FoundationModelsACP
import FoundationModelsRouter
import Logging

/// The consumer of a prompt's `session/update` payloads. The production
/// sink posts through the bound `AgentSideConnection`; a test sink
/// records the sequence.
typealias SessionUpdateSink = @Sendable (SessionUpdate) async -> Void

extension AgentSideConnection {
  /// Sends one `session/update` for `sessionId`. A send failure is
  /// logged and dropped: the prompt already returned its response,
  /// so no prompt error can become a JSON-RPC error, and a closed
  /// connection has no reader to correct.
  ///
  /// - Parameters:
  ///   - update: The update payload.
  ///   - sessionId: The session the update belongs to.
  func post(_ update: SessionUpdate, in sessionId: SessionId) async {
    do {
      try await sessionUpdate(
        UpdateSessionNotification(sessionId: sessionId, update: update))
    } catch {
      ACPAgentTelemetry.logger(.promptExecution).warning(
        "A session/update send failed.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
    }
  }
}

/// The `state_update` of one ACP session. It is `requires_action` while a question of the session
/// waits for the user. Else it is `running` while the session is busy. Else it is `idle`.
///
/// The session is busy while Router works (``workStarted(on:)`` and ``workEnded(on:)``) or a prompt
/// is open. Router work is an open background run, an answer that runs, or queued run mail. A run
/// that waits only for the user is no work. So an open question does not keep the session busy. A
/// prompt counts too, because some prompts make no Router work. Examples are a slash command with
/// no model pass and a refused mail. Another example is a prompt cancelled before its mail went in.
/// The ledger keeps the set of the Router sessions that work, by their ids.
///
/// A question waits for the user from ``userWaitStarted(_:)`` to
/// ``userWaitEnded(_:resumedWork:since:)``. The relay calls them for each
/// question that this session holds. The copy of a child question does not
/// count.
///
/// An `idle` carries the stop reason and the error of the last prompt that
/// ended since the last `running`. When only background work ran since the
/// last `running`, the `idle` has no stop reason. A prompt that ends while
/// Router still works sends no `idle`. The `idle` comes when the work ends.
///
/// Every `state_update` carries the `background` list: the work that runs apart from the
/// foreground work (``BackgroundBook``). The list is `[]` when nothing runs apart. The sources of
/// the work tell the ledger through ``background(_:)``, after the wire update of the change went
/// out. When the list changes, the ledger sends the state again with the new list.
///
/// The ledger sends one update at a time, in the order of the decisions.
/// The sink suspends, and the actor is reentrant. So each send waits for the
/// turn of the sends before it. A later change never overtakes an earlier
/// change or an earlier snapshot.
actor SessionStateLedger {
  /// The receiver of the activity of a session. A parent ledger listens to its child.
  ///
  /// - Parameters:
  ///   - isActive: Whether the session works, or runs work apart.
  ///   - version: The number of the change. A newer change has a larger number.
  typealias SessionActivityObserver = @Sendable (_ isActive: Bool, _ version: Int) async -> Void

  /// The state that the ledger reported last.
  private enum Reported {
    /// The session is not busy.
    case idle

    /// The session is busy.
    case running

    /// A question of the session waits for the user.
    case requiresAction
  }

  /// The sink the changes go to. It records into the history and sends.
  private let send: SessionUpdateSink

  /// The sink a snapshot goes to. It sends and records nothing.
  private let announce: SessionUpdateSink

  /// The number of prompts that started and did not end.
  private var openCount = 0

  /// The ids of the Router sessions that work now.
  private var workingSources: Set<ULID> = []

  /// The ids of the questions that wait for the user now.
  private var waitingQuestions: Set<String> = []

  /// The number of work events that the ledger took (``workStarted(on:)``
  /// and ``workEnded(on:)``).
  private var workEventCount = 0

  /// The number of answers that Router took and that resume a run. The ledger did not take the
  /// work event of these answers yet. Such an answer keeps the session busy. A work event ends
  /// the count.
  private var answersResuming = 0

  /// The state that the last change reported.
  private var reported = Reported.idle

  /// The `idle` of the last prompt that ended since the last `running`,
  /// or `nil` when no prompt ended since then.
  private var lastPromptEnd: IdleStateUpdate?

  /// The work that runs apart from the foreground work.
  private var book = BackgroundBook()

  /// The list that the last state update carried.
  private var reportedBackground: [BackgroundWork] = []

  /// The receiver of the activity of this session, or `nil` for a root session.
  private var activityObserver: SessionActivityObserver?

  /// The number of changes of the activity of this session.
  private var activityVersion = 0

  /// Whether the last noted activity was active.
  private var wasActive = false

  /// The newest activity version of each child, so an old report is not taken.
  private var childActivityVersions: [SessionId: Int] = [:]

  /// Whether a send runs now.
  private var isSending = false

  /// The sends that wait for their turn, in order.
  private var turnWaiters: [CheckedContinuation<Void, Never>] = []

  /// Creates the ledger over `send`.
  ///
  /// - Parameters:
  ///   - send: The sink every state change goes to.
  ///   - announce: The sink a snapshot goes to. It defaults to `send`.
  init(send: @escaping SessionUpdateSink, announce: SessionUpdateSink? = nil) {
    self.send = send
    self.announce = announce ?? send
  }

  /// Whether a prompt is open now.
  var hasOpenPrompt: Bool {
    openCount > 0
  }

  /// The list of the work that runs apart now: what the next state update carries.
  var backgroundList: [FoundationModelsACP.BackgroundWork] {
    book.list
  }

  /// Whether the session is idle now: the state that a snapshot of the session carries.
  var isIdle: Bool {
    current == .idle
  }

  /// Whether the session is busy: Router works, or a prompt is open.
  private var isBusy: Bool {
    openCount > 0 || !workingSources.isEmpty || answersResuming > 0
  }

  /// The number of work events that the ledger took. The relay reads it
  /// before it gives an answer to Router (``userWaitEnded(_:resumedWork:since:)``).
  var workEventMark: Int {
    workEventCount
  }

  /// The state that the session has now.
  private var current: Reported {
    if !waitingQuestions.isEmpty {
      return .requiresAction
    }
    return isBusy ? .running : .idle
  }

  /// Counts one more open prompt, and sends `running` when the session
  /// was not busy.
  func promptStarted() async {
    openCount += 1
    await sendChange()
  }

  /// Counts one prompt less, and keeps its `idle` for the next `idle` of
  /// the session. Sends that `idle` when the session is not busy any more.
  ///
  /// - Parameters:
  ///   - idle: The `idle` of the prompt that ends.
  ///   - started: Whether the prompt started (``promptStarted()``). A
  ///     prompt that ends before its start counts nothing, but it still
  ///     sends its `idle` when the session is not busy.
  func promptEnded(_ idle: IdleStateUpdate, started: Bool) async {
    if started {
      openCount -= 1
    }
    lastPromptEnd = idle
    if !started, !isBusy, reported == .idle {
      lastPromptEnd = nil
      await deliver(.stateUpdate(stamped(.idle(idle.sayingNoWork()))), recorded: true)
      return
    }
    await sendChange()
  }

  /// Records that the Router session `source` has work now
  /// (`SessionEvent.workStarted`).
  ///
  /// - Parameter source: The id of the Router session.
  func workStarted(on source: ULID) async {
    takeWorkEvent()
    workingSources.insert(source)
    await sendChange()
  }

  /// Records that the Router session `source` has no work now
  /// (`SessionEvent.workEnded`), or that its feed ended. Router sends no
  /// work event after `close()` starts.
  ///
  /// - Parameter source: The id of the Router session.
  func workEnded(on source: ULID) async {
    takeWorkEvent()
    workingSources.remove(source)
    await sendChange()
  }

  /// Records that the question `question` waits for the user now. It sends `requires_action` when
  /// the session did not report it yet.
  ///
  /// - Parameter question: The elicitation id of the question.
  func userWaitStarted(_ question: String) async {
    waitingQuestions.insert(question)
    await sendChange()
  }

  /// Records that the question `question` does not wait for the user any more. It sends `running`
  /// or `idle` when no other question waits.
  ///
  /// An answer that Router took resumes a run, and Router then sends a work
  /// event. The ledger can take the end of the wait before that event. So
  /// it keeps the session busy until the next work event. This sends no
  /// `idle` between the answer and the work. The ledger does this only when
  /// it took no work event since `mark`.
  ///
  /// - Parameters:
  ///   - question: The elicitation id of the question.
  ///   - resumedWork: Whether Router took the answer, so a run resumes.
  ///   - mark: ``workEventMark`` as it was before the answer went to
  ///     Router.
  func userWaitEnded(_ question: String, resumedWork: Bool = false, since mark: Int = 0) async {
    waitingQuestions.remove(question)
    if resumedWork, workEventCount == mark {
      answersResuming += 1
    }
    await sendChange()
  }

  /// Counts one work event, which ends the wait for the work of the
  /// answers that Router took.
  private func takeWorkEvent() {
    workEventCount += 1
    answersResuming = 0
  }

  /// The current state of the session, for a `session/resume` sync.
  ///
  /// The `idle` carries no stop reason and no error. A snapshot is not a
  /// new completion and not a new cancellation. The client already got the
  /// stop reason of the last prompt. The snapshot changes nothing in the
  /// ledger. It carries the list of the work that runs apart now.
  ///
  /// - Returns: The current state.
  func currentSnapshot() -> StateUpdate {
    stamped(currentState)
  }

  /// Sends the current state (``currentSnapshot()``), also when it equals
  /// the last state that went out.
  ///
  /// The snapshot goes to the announce sink, so it does not replace the
  /// retained state of the history. It waits for its turn, as the changes
  /// do. A change that the ledger took before the snapshot is sent before
  /// it. A change that it takes later is sent after it.
  func announceCurrentState() async {
    await deliver(.stateUpdate(currentSnapshot()), recorded: false)
  }

  /// Takes one change of the work that runs apart from the foreground work. It sends the state
  /// again when the list changes.
  ///
  /// The source calls this after the wire update of the change went out. So the list names an
  /// item only after its announcement, and it drops the item after its final status.
  ///
  /// - Parameter change: The change.
  func background(_ change: BackgroundChange) async {
    book.apply(change)
    await sendChange()
  }

  /// The receiver of the changes of the work that runs apart. It takes each change into this
  /// ledger (``background(_:)``).
  nonisolated var backgroundReport: BackgroundReport {
    { await self.background($0) }
  }

  /// Sets the receiver of the activity of this session. A child session tells its parent
  /// through it. The parent lists the child while the child is active.
  ///
  /// - Parameter observer: The receiver.
  func observeActivity(_ observer: @escaping SessionActivityObserver) {
    activityObserver = observer
  }

  /// Records that the `subagent_update` of a child went to the client.
  ///
  /// - Parameter child: The child session.
  func subagentAnnounced(_ child: SessionId) async {
    await background(.subagentAnnounced(child))
  }

  /// Takes the activity of a child session. A report that is older than the last one is dropped:
  /// the reports of one child can arrive in another order than they were made.
  ///
  /// - Parameters:
  ///   - child: The child session.
  ///   - isActive: Whether the child works, or runs work apart.
  ///   - version: The number of the report of the child.
  func subagentActivity(_ child: SessionId, isActive: Bool, version: Int) async {
    guard version > childActivityVersions[child, default: 0] else {
      return
    }
    childActivityVersions[child] = version
    await background(.subagentActivity(child, isActive: isActive))
  }

  /// Records that a child session is gone.
  ///
  /// - Parameter child: The child session.
  func subagentRetired(_ child: SessionId) async {
    childActivityVersions.removeValue(forKey: child)
    await background(.subagentRetired(child))
  }

  /// The state that the session has now, with no stop reason and no list.
  private var currentState: StateUpdate {
    switch current {
    case .requiresAction:
      return .requiresAction(RequiresActionStateUpdate())
    case .running:
      return .running(RunningStateUpdate())
    case .idle:
      return .idle(IdleStateUpdate().sayingNoWork())
    }
  }

  /// A state with the list of the work that runs apart now. The ledger notes this list as the
  /// one that the client holds.
  ///
  /// - Parameter state: The state to send.
  /// - Returns: The state with the list.
  private func stamped(_ state: StateUpdate) -> StateUpdate {
    let list = book.list
    reportedBackground = list
    return state.reporting(background: list)
  }

  /// Sends the new state when the state of the session or the list changed since the last
  /// report. Then it tells the observer when the session became active or idle.
  private func sendChange() async {
    let activity = noteActivity()
    await deliverChange()
    if let activity {
      await activityObserver?(activity.isActive, activity.version)
    }
  }

  /// Notes whether the session is active now: it works, or it runs work apart.
  ///
  /// - Returns: The new activity, or `nil` when it did not change.
  private func noteActivity() -> (isActive: Bool, version: Int)? {
    let isActive = current != .idle || !book.list.isEmpty
    guard isActive != wasActive else {
      return nil
    }
    wasActive = isActive
    activityVersion += 1
    return (isActive, activityVersion)
  }

  /// Sends the new state when the state of the session changed since the last report. When only
  /// the list changed, it sends the current state again.
  private func deliverChange() async {
    let next = current
    guard next != reported else {
      await resendWhenListChanged()
      return
    }
    let previous = reported
    reported = next
    await deliver(
      .stateUpdate(stamped(update(entering: next, from: previous))), recorded: true)
  }

  /// Sends the current state again when the list is not the one that the client holds. The state
  /// did not change, so this is no new event of the session. It records nothing in the history.
  private func resendWhenListChanged() async {
    guard book.list != reportedBackground else {
      return
    }
    await deliver(.stateUpdate(stamped(currentState)), recorded: false)
  }

  /// The state update for a change of the reported state.
  ///
  /// - Parameters:
  ///   - next: The state that the session enters.
  ///   - previous: The state that the session leaves.
  /// - Returns: The update.
  private func update(entering next: Reported, from previous: Reported) -> StateUpdate {
    switch next {
    case .requiresAction:
      forgetPromptEnd(after: previous)
      return .requiresAction(RequiresActionStateUpdate())
    case .running:
      forgetPromptEnd(after: previous)
      return .running(RunningStateUpdate())
    case .idle:
      let idle = lastPromptEnd ?? IdleStateUpdate()
      lastPromptEnd = nil
      return .idle(idle.sayingNoWork())
    }
  }

  /// Drops the `idle` of the last prompt when the session leaves `idle`.
  /// A new stretch of work starts, and the old stop reason is not part
  /// of it.
  ///
  /// - Parameter previous: The state that the session leaves.
  private func forgetPromptEnd(after previous: Reported) {
    if previous == .idle {
      lastPromptEnd = nil
    }
  }

  /// Sends one update to the sink of its kind, when it is its turn.
  ///
  /// - Parameters:
  ///   - update: The update.
  ///   - recorded: Whether the update goes to the sink that records into
  ///     the history.
  private func deliver(_ update: SessionUpdate, recorded: Bool) async {
    await takeTurn()
    await (recorded ? send : announce)(update)
    passTurn()
  }

  /// Suspends until the sends before this one are done. The turns go in
  /// the order of the calls.
  private func takeTurn() async {
    guard isSending else {
      isSending = true
      return
    }
    await withCheckedContinuation { turnWaiters.append($0) }
  }

  /// Gives the turn to the next waiting send, or ends the sending.
  private func passTurn() {
    if turnWaiters.isEmpty {
      isSending = false
    } else {
      turnWaiters.removeFirst().resume()
    }
  }
}

/// The prompt-state owner of one prompt.
///
/// It gives the transitions of its prompt to the ``SessionStateLedger`` of the session. These are
/// the start and the end with a stop reason. The ledger decides which state update goes out. More
/// than one prompt can be open, and Router work keeps the session busy too. The ledger also reports
/// `requires_action` while a question waits for the user. This owner does not know the questions.
/// It also records a `session/cancel` request. So the prompt ends as `cancelled` even when the
/// cancelled model work runs to completion. Model work that never checks for cancellation returns
/// its response. It does not throw.
actor PromptStateOwner {
  /// The state ledger of the session.
  private let ledger: SessionStateLedger

  /// Whether `session/cancel` asked this prompt to stop.
  private(set) var cancelRequested = false

  /// Whether ``promptDidStart()`` already sent `running` for the prompt.
  private var didStart = false

  /// The stop reason that the `idle` terminator carried, or `nil` while the
  /// prompt runs: a value tells that ``promptDidEnd(stop:)`` sent the
  /// terminator. `session/close` reads it, so the close response follows
  /// the terminator, and the prompt span reads it when it
  /// ends.
  private(set) var stopReason: StopReason?

  /// Whether ``promptDidEnd(stop:)`` runs or ran: a second call changes
  /// nothing.
  private var isEnding = false

  /// The waiters suspended in ``waitForPromptEnd()`` until the terminator
  /// goes out.
  private var endWaiters: [CheckedContinuation<Void, Never>] = []

  /// Creates the owner of one prompt of the session of `ledger`.
  ///
  /// - Parameter ledger: The state ledger of the session.
  init(ledger: SessionStateLedger) {
    self.ledger = ledger
  }

  /// Creates the owner of the only prompt of a session that has no other
  /// prompt, over `send`: a synthetic prompt of a test.
  ///
  /// - Parameter send: The sink every state update goes to.
  init(send: @escaping SessionUpdateSink) {
    self.init(ledger: SessionStateLedger(send: send))
  }

  /// Starts the prompt one time. The prompt calls it before its mail
  /// goes into the session (the fixed order of task 49), and the projector
  /// calls it at each Router `submissionStarted` event of the prompt. Only
  /// the first call counts.
  func promptDidStart() async {
    guard !didStart, !isEnding else { return }
    didStart = true
    await ledger.promptStarted()
  }

  /// Ends the prompt with `stop`: the ledger keeps the `idle` with the
  /// stop reason, and with the `error` object of a failed prompt
  /// (``PromptExecution/idleState(for:)``), and sends it when the session
  /// is not busy any more (``SessionStateLedger``).
  /// The end of the prompt calls it, never a `submissionEnded` event,
  /// because one prompt can make more than one submission. A second call
  /// changes nothing.
  ///
  /// - Parameter stop: Why the prompt stopped.
  /// - Returns: The stop reason of the prompt.
  @discardableResult
  func promptDidEnd(stop: PromptStop) async -> StopReason {
    let reason = PromptExecution.stopReason(for: stop)
    guard !isEnding else {
      return stopReason ?? reason
    }
    isEnding = true
    await ledger.promptEnded(PromptExecution.idleState(for: stop), started: didStart)
    stopReason = reason
    let waiters = endWaiters
    endWaiters = []
    for waiter in waiters {
      waiter.resume()
    }
    return reason
  }

  /// Suspends until the prompt ended. A close during an active prompt
  /// awaits it, so the client learns the prompt ended before the close
  /// response. If not, a client with a spinner does not learn that the
  /// prompt ended. It returns at once when the prompt already ended.
  func waitForPromptEnd() async {
    guard stopReason == nil else {
      return
    }
    await withCheckedContinuation { continuation in
      endWaiters.append(continuation)
    }
  }

  /// Records that `session/cancel` asked this prompt to stop. The
  /// prompt reads it at the end, because a cancelled prompt does not
  /// always throw: model work that never checks for cancellation runs to
  /// completion.
  func noteCancelRequested() {
    cancelRequested = true
  }
}

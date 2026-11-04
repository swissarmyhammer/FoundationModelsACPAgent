import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Logging

/// The one reader of the events of one ACP session, from the open of the
/// session to its close.
/// (See elicitation-plan tasks 1, 4 and 5, and `mailbox.md`, section 3, item 4.)
///
/// The projector reads `streamSessionEvents()` of each Router session that
/// the ACP session uses.
/// It is the root session. A model slot switch gives the projector a
/// restored session with the same id (``replace(with:)``).
/// It sends each event to the client through one
/// ``ACPEventTranslator``, in the order of one inbox.
/// Thus the client also gets an event that comes while no prompt is open.
/// Such an event is a run result or a compaction.
///
/// A prompt is one record in the projector.
/// The record holds its `MailID`, its prompt-state owner and the work to run at its end.
/// More than one prompt can be open.
/// The prompt opens before its mail goes into the session, so each event of the mail finds the record.
/// An event counts for a prompt (``PromptTally``) only when its origin holds the `MailID` of that prompt.
/// The prompt ends at the terminal event of its `MailID`: `answered`, `answerFailed`, `cancelled` or `lost`.
/// Later work goes to the client with no prompt open, and sends no state update.
/// An example is the answer that the mail of a background run starts.
///
/// One task reads the inbox and owns the translator, so no two events are
/// translated at the same time. The inbox has no bound: the Router
/// subscription and the inbox keep each event, and no event is lost.
actor SessionProjector {
  /// One prompt that the projector ends at the terminal event of its mail.
  struct Prompt: Sendable {
    /// The id of the mail of the prompt.
    let mailId: MailID

    /// The id of the Router session that the mail goes into. When that
    /// session closes with the prompt still open, the prompt ends.
    let sourceId: ULID

    /// The `awaitAnswer(of:)` of the Router session that the mail goes
    /// into.
    /// The typed error of a failed answer comes from it.
    let awaitAnswer: @Sendable (MailID) async throws -> SessionAnswer

    /// The prompt-state owner of the prompt.
    let owner: PromptStateOwner

    /// The model reference that the prompt generates with, for the logs.
    let modelName: String

    /// The work to run after the `idle` of the prompt went out, with the
    /// stop reason of that `idle`.
    /// It is the end of the telemetry and the clear of the prompt in the session table.
    let onEnd: @Sendable (StopReason) async -> Void
  }

  /// One source of outputs: a Router session that the projector reads.
  struct Source: Sendable {
    /// The id of the Router session.
    let id: ULID

    /// The Router session, which the answer of an elicitation goes back to.
    /// It is `nil` for a synthetic source of a test.
    let session: (any RoutedSession)?
  }

  /// One item of the inbox, in the order that the projector handles it.
  enum Input: Sendable {
    /// One output of a source that the projector reads.
    case output(SessionOutput, from: Source)

    /// The outputs of a source ended: its Router session closed.
    case sourceEnded(ULID)

    /// A prompt opens. It comes before the mail of the prompt.
    case openPrompt(Prompt)

    /// The mail of a prompt was refused, after the prompt opened.
    case mailRefused(MailID, message: String)

    /// The prompt of the mail was cancelled before its mail went into
    /// the session.
    case mailCancelled(MailID)

    /// `session/cancel` sent the `cancelForeground()` signal with this id.
    case cancelSent(SignalID)

    /// One update of a slash command, which sends no Router event, and
    /// the wait of the sender for its send.
    case update(SessionUpdate, sent: CheckedContinuation<Void, Never>?)

    /// The run of the session ended, with this `idle`. It comes after the
    /// last output of each source, and the sender waits for its handling.
    case runEnded(IdleStateUpdate, handled: CheckedContinuation<Void, Never>)

    /// The hold on the final status of an `agents` call ends. The projector
    /// sends the statuses that the hold kept, in its own order.
    case releaseHold(token: String, handled: CheckedContinuation<Void, Never>)
  }

  /// The relay of the elicitations of the session, or `nil` when the agent
  /// has no bound connection.
  nonisolated let relay: ElicitationRelay?

  /// The join table of the session, which the translator writes.
  nonisolated let runCallJoins: RunCallJoinTable

  /// The input end of the inbox.
  private nonisolated let inbox: AsyncStream<Input>.Continuation

  /// The task that reads the inbox.
  private let consumer: Task<Void, Never>

  /// The reader task of each Router session, keyed by the id of the
  /// session.
  private var readers: [ULID: Task<Void, Never>] = [:]

  /// Whether ``stop()`` ran.
  private var isStopped = false

  /// Makes the projector and starts its inbox reader. Call ``attach(_:)``
  /// for the root session before anything mails the session.
  ///
  /// - Parameters:
  ///   - sessionId: The id of the ACP session.
  ///   - parentSessionId: The id of the parent of the session, or `nil` for a root session.
  ///   - modelName: The model reference of the session, for the logs.
  ///   - send: The history sink of the session.
  ///   - shellSnapshot: The reader of the stored output of a settled run.
  ///   - relay: The elicitation relay, or `nil` for none.
  ///   - runCallJoins: The join table of the session.
  ///   - stateLedger: The state ledger of the session, which takes the
  ///     work events of each Router session, or `nil` for none.
  init(
    sessionId: SessionId,
    parentSessionId: SessionId? = nil,
    modelName: String,
    send: @escaping SessionUpdateSink,
    shellSnapshot: @escaping ShellSnapshotProvider = { _ in nil },
    relay: ElicitationRelay?,
    runCallJoins: RunCallJoinTable,
    stateLedger: SessionStateLedger? = nil
  ) {
    self.relay = relay
    self.runCallJoins = runCallJoins
    // The final status of an `agents` call waits for the end of its child
    // (``AgentCallHolds``). Each send of the session goes through the hold.
    // The ledger learns of each update after the update went out, below the hold. So a call
    // whose final status the hold keeps back stays on the background list.
    let background = BackgroundWatch()
    let announcing =
      stateLedger.map { background.reporting(sentThrough: send, to: $0.backgroundReport) } ?? send
    let send = runCallJoins.deferringFinalStatus(of: announcing)
    let (stream, inbox) = AsyncStream.makeStream(of: Input.self)
    self.inbox = inbox
    runCallJoins.openProjection()
    consumer = Task {
      var state = ProjectionState(
        translator: ACPEventTranslator(
          sessionId: sessionId, parentSessionId: parentSessionId, send: send, modelName: modelName,
          shellSnapshot: shellSnapshot,
          runCallJoins: runCallJoins),
        send: send,
        holds: runCallJoins.holds,
        relay: relay,
        stateLedger: stateLedger,
        background: background)
      if let relay {
        let endElicitation: ElicitationEndHandler = { end in await relay.end(end) }
        state.translator.endElicitation = endElicitation
        let completeElicitation: ElicitationCompletionHandler = { completion in
          await relay.complete(completion)
        }
        state.translator.completeElicitation = completeElicitation
      }
      for await input in stream {
        await state.handle(input)
      }
      await state.endOpenPrompts(stop: .cancelled)
      // Router ended each open question before the end of the feed.
      // A round trip that is still in flight is a defect.
      // The relay ends it with a warning, so its tool resumes.
      await relay?.drainOpenRoundTrips()
    }
  }

  /// Starts to read the events of `session`. The subscription is taken
  /// before this call returns, so it holds each event that the session
  /// sends after the call. A second call for the same session, and a call
  /// after ``stop()``, do nothing.
  ///
  /// - Parameter session: The Router session to read.
  func attach(_ session: any RoutedSession) async {
    guard !isStopped, readers[session.id] == nil else {
      return
    }
    attach(await session.streamSessionEvents(), from: Source(id: session.id, session: session))
  }

  /// Reads the events of the session that replaces the session of the same id.
  /// A model slot switch restores the Router session with the id that it had.
  /// The caller closed the old session, so the reader of the old session ends
  /// after its last event. This method waits for that end and then reads the
  /// new session. The end of the old reader goes into the inbox before any
  /// event of the new session, so it never ends a prompt of the new session.
  /// After ``stop()``, do nothing.
  ///
  /// - Parameter session: The restored Router session to read.
  func replace(with session: any RoutedSession) async {
    if let reader = readers.removeValue(forKey: session.id) {
      await reader.value
    }
    await attach(session)
  }

  /// Starts to read `outputs` as the outputs of `source`. A synthetic test
  /// gives its own outputs here; ``attach(_:)`` gives the outputs of a
  /// Router session.
  ///
  /// - Parameters:
  ///   - outputs: The outputs, in order.
  ///   - source: The source of the outputs.
  func attach(_ outputs: AsyncStream<SessionOutput>, from source: Source) {
    guard !isStopped, readers[source.id] == nil else {
      return
    }
    let inbox = self.inbox
    readers[source.id] = Task {
      for await output in outputs {
        inbox.yield(.output(output, from: source))
      }
      inbox.yield(.sourceEnded(source.id))
    }
  }

  /// Opens a prompt.
  /// Call it before the mail of the prompt goes into the session.
  /// Then the projector has the record when the first event of the mail comes.
  ///
  /// - Parameter prompt: The prompt.
  nonisolated func open(_ prompt: Prompt) {
    inbox.yield(.openPrompt(prompt))
  }

  /// Tells the projector that the session refused the mail of an open prompt.
  /// The prompt ends with the error text as an agent message.
  /// It also ends with an `idle` with the `error` stop reason (task ^he1rmw6, decision G3).
  ///
  /// - Parameters:
  ///   - mailId: The id of the refused mail.
  ///   - error: The error that `mail(_:)` threw.
  nonisolated func refuseMail(_ mailId: MailID, error: any Error) {
    inbox.yield(.mailRefused(mailId, message: String(describing: error)))
  }

  /// Tells the projector that the prompt of the mail `mailId` was
  /// cancelled before its mail went into the session. The prompt ends as
  /// `cancelled`, and no mail goes in.
  ///
  /// - Parameter mailId: The id of the mail that the prompt did not send.
  nonisolated func cancelUnsentMail(_ mailId: MailID) {
    inbox.yield(.mailCancelled(mailId))
  }

  /// Tells the projector the id of the `cancelForeground()` signal of a
  /// `session/cancel`.
  /// Each open prompt that the cancel reached ends as `cancelled`.
  /// It ends no later than the `signalDone` event of that signal.
  /// So the `idle` with the `cancelled` stop reason ends the cancel (an ACP
  /// rule; task ^9xs24pn, decision G6).
  ///
  /// - Parameter signal: The id of the `cancelForeground()` signal.
  nonisolated func cancelSent(_ signal: SignalID) {
    inbox.yield(.cancelSent(signal))
  }

  /// The sink of a slash command.
  /// Each update goes through the inbox.
  /// So it keeps its order with the events of the session.
  /// The sink returns when the update went out.
  /// So the end of the command comes after each update of the command.
  /// The state ledger of the session sends the end of the command.
  /// After ``stop()``, an update goes nowhere.
  nonisolated var commandSink: SessionUpdateSink {
    { [inbox] update in
      await Self.yieldAndWait(to: inbox) { .update(update, sent: $0) }
    }
  }

  /// Offers one item to the inbox, and suspends until the consumer handled
  /// it.
  /// Three senders wait for their item: the command sink, the end of a run and the end of a hold.
  /// They use this one handshake.
  ///
  /// - Parameters:
  ///   - inbox: The input end of the inbox.
  ///   - ifTerminated: The work to do when the inbox is terminated and the
  ///     item went nowhere. It runs before the wait ends. Nothing by default.
  ///   - makeInput: Makes the item from the continuation that the consumer
  ///     resumes when it handled the item.
  private nonisolated static func yieldAndWait(
    to inbox: AsyncStream<Input>.Continuation,
    ifTerminated: () -> Void = {},
    _ makeInput: (CheckedContinuation<Void, Never>) -> Input
  ) async {
    await withCheckedContinuation { handled in
      if case .terminated = inbox.yield(makeInput(handled)) {
        ifTerminated()
        handled.resume()
      }
    }
  }

  /// Ends the session of a run.
  /// It waits until each source sent its last output.
  /// Then it reports the usage of the run, and the end of the run with `idle`.
  /// The usage is that of this session only, with no cost.
  /// The `idle` goes out after each update that the session sent.
  /// It carries the stop reason of the run.
  /// The caller finishes the outputs of each source first.
  /// A source that never ends holds this call.
  ///
  /// - Parameter idle: The `idle` that tells how the run ended.
  func end(with idle: IdleStateUpdate) async {
    for reader in Array(readers.values) {
      await reader.value
    }
    await Self.yieldAndWait(to: inbox) { .runEnded(idle, handled: $0) }
  }

  /// Ends the hold on the final status of the `agents` call of a run.
  /// It also sends the statuses that the hold kept.
  /// They go through the inbox.
  /// So each update that came before stays before them.
  /// Each update that comes after goes after them.
  /// After ``stop()``, the hold ends and the kept statuses go nowhere.
  ///
  /// - Parameter token: The completion token of the call that started the run.
  nonisolated func releaseHold(of token: String) async {
    await Self.yieldAndWait(
      to: inbox, ifTerminated: { _ = runCallJoins.holds.release(token) },
      { .releaseHold(token: token, handled: $0) })
  }

  /// Stops the projector after each item in the inbox. A prompt that is
  /// still open ends as `cancelled`. Safe to call more than one time.
  ///
  /// The reader of each source in `closed` reads to the natural end of its
  /// outputs.
  /// The caller closed that Router session, and the close ends
  /// the subscription after its last event.
  /// Thus the projector sends each event of a closed session.
  /// The stop does not depend on how a cancelled stream treats the outputs that it still holds.
  /// The stop cancels the reader of each other source.
  ///
  /// - Parameter closed: The ids of the sources whose outputs ended or
  ///   end without a cancel.
  func stop(after closed: Set<ULID> = []) async {
    guard !isStopped else {
      await consumer.value
      return
    }
    isStopped = true
    for (sourceId, reader) in readers {
      if !closed.contains(sourceId) {
        reader.cancel()
      }
      await reader.value
    }
    inbox.finish()
    await consumer.value
    runCallJoins.closeProjection()
  }
}

// MARK: - The state of the inbox reader

/// The state that the inbox reader of a ``SessionProjector`` owns: the
/// translator and the open prompts.
private struct ProjectionState {
  /// One open prompt and its counts.
  struct OpenPrompt {
    /// The record of the prompt.
    let prompt: SessionProjector.Prompt

    /// The counts of the prompt.
    var tally = PromptTally()

    /// The tool calls that went to the client while the prompt was open.
    /// So the end of the prompt can close each one that did not finish.
    /// It takes the tool-call updates of the prompt.
    /// It also takes the updates of each other work.
    /// An example is the settlement of a run of the prompt, which has the origin of its run mail.
    /// It never takes an update of another prompt.
    let toolCalls = PromptToolCalls()
  }

  /// The translator of the events of the session.
  var translator: ACPEventTranslator

  /// The history sink of the session.
  let send: SessionUpdateSink

  /// The holds on the final status of the `agents` calls of the surface.
  let holds: AgentCallHolds

  /// The relay of the elicitations of the session, or `nil`.
  let relay: ElicitationRelay?

  /// The state ledger of the session, or `nil` for a synthetic test that
  /// reads no work state.
  let stateLedger: SessionStateLedger?

  /// The watch of the runs that go on after their SDK call returned.
  let background: BackgroundWatch

  /// The open prompts, in the order that they opened. A stream message
  /// goes alone in its submission, so an event holds the `MailID` of at
  /// most one prompt.
  var open: [OpenPrompt] = []

  /// The counts of the events that belong to no open prompt: the run of a
  /// sub-agent session. The end of the run reports them in its one
  /// `usage_update` (``SessionProjector/end(with:)``). The counts are those
  /// of this session only. A parent never adds the counts of its child, and
  /// a child never adds the counts of its parent.
  var runTally = PromptTally()

  /// The `cancelForeground()` signals of `session/cancel` whose `signalDone` did
  /// not come yet.
  var pendingCancels: Set<SignalID> = []

  /// The ids of the last `signalDone` events.
  /// So a ``SessionProjector/Input/cancelSent(_:)`` that comes after the event of its signal still finds it.
  /// The reader of the session and the sender of the cancel are two tasks.
  var recentSignalsDone: [SignalID] = []

  /// The number of ids that ``recentSignalsDone`` keeps.
  static let recentSignalsDoneLimit = 64

  /// Handles one item of the inbox.
  ///
  /// - Parameter input: The item.
  mutating func handle(_ input: SessionProjector.Input) async {
    switch input {
    case .output(let output, let source):
      await project(output, from: source)
    case .sourceEnded(let sourceId):
      // A closed Router session sends no terminal for the mail of a
      // prompt that is still open on it. The end of the reader of a
      // replaced session does not stop the projector.
      for prompt in open.map(\.prompt) where prompt.sourceId == sourceId {
        await endPrompt(prompt.mailId, stop: .cancelled)
      }
      // Router sends no work event after `close()` starts, so the end
      // of the feed ends the work of that session.
      await stateLedger?.workEnded(on: sourceId)
    case .openPrompt(let prompt):
      open.append(OpenPrompt(prompt: prompt))
      translator.modelName = prompt.modelName
    case .mailRefused(let mailId, let message):
      guard open.contains(where: { $0.prompt.mailId == mailId }) else {
        return
      }
      await send(
        .agentMessageChunk(
          ContentChunk(
            content: .text(TextContent(text: message)),
            messageId: ACPEventTranslator.makeMessageId())))
      await endPrompt(mailId, stop: .failed(message: message))
    case .mailCancelled(let mailId):
      await endPrompt(mailId, stop: .cancelled)
    case .cancelSent(let signal):
      if recentSignalsDone.contains(signal) {
        await endCancelledPrompts()
      } else {
        pendingCancels.insert(signal)
      }
    case .update(let update, let sent):
      await send(update)
      sent?.resume()
    case .runEnded(let idle, let handled):
      await endRun(with: idle)
      handled.resume()
    case .releaseHold(let token, let handled):
      for update in holds.release(token) {
        await send(.toolCallUpdate(update))
      }
      handled.resume()
    }
  }

  /// Translates one output.
  /// It counts the output for the open prompt whose mail its origin holds.
  /// It ends a prompt at the terminal event of its mail or at the stall bound.
  ///
  /// - Parameters:
  ///   - output: The output.
  ///   - source: The source that sent the output.
  private mutating func project(_ output: SessionOutput, from source: SessionProjector.Source) async
  {
    let event = output.event
    let index = open.firstIndex { output.origin.contains($0.prompt.mailId) }
    if let index, case .submissionStarted = event {
      await open[index].prompt.owner.promptDidStart()
    }
    translator.tally = index.map { open[$0].tally } ?? runTally
    let recorders = index.map { [open[$0].toolCalls] } ?? open.map(\.toolCalls)
    translator.send = recorders.reduce(send) { sink, toolCalls in toolCalls.recording(into: sink) }
    translator.relayElicitation = relayHandler(for: source.session)
    background.willTranslate(event)
    await translator.project(event)
    for change in background.didTranslate(event, joins: translator.runCallJoins) {
      await stateLedger?.background(change)
    }
    // The work state of the session (elicitation-plan task 2): the ledger
    // sends `running` and `idle` from it. A prompt that ended at an
    // earlier event already gave the ledger its stop reason.
    switch event {
    case .workStarted:
      await stateLedger?.workStarted(on: source.id)
    case .workEnded:
      await stateLedger?.workEnded(on: source.id)
    default:
      break
    }
    if let index {
      open[index].tally = translator.tally
      let current = open[index]
      if case .generationStalled(let stall) = event,
        PromptExecution.endsPrompt(stall, sawOutput: current.tally.sawOutput)
      {
        PromptExecution.report(
          stall, sessionId: translator.sessionId, parent: translator.parentSessionId,
          modelName: current.prompt.modelName)
        await endPrompt(current.prompt.mailId, stop: .stalled(stall))
        return
      }
    } else {
      runTally = translator.tally
    }
    for prompt in open.map(\.prompt) {
      if let stop = await Self.stop(
        of: event, ending: prompt, sessionId: translator.sessionId,
        parent: translator.parentSessionId)
      {
        await endPrompt(prompt.mailId, stop: stop)
      }
    }
    if case .signalDone(let signal) = event {
      await signalDone(signal)
    }
  }

  /// Ends the run of the session: the one `usage_update` of the run, then the end of the work
  /// state. The `usage_update` has the context of the last submission of the run and no cost.
  /// The cost of a child is unknown, not zero, and a client must not add the cost of a parent
  /// and of its children. The counts start again for a next run.
  ///
  /// - Parameter idle: The `idle` that tells how the run ended.
  private mutating func endRun(with idle: IdleStateUpdate) async {
    if let usage = runTally.usageUpdate {
      await send(.usageUpdate(usage))
    }
    runTally = PromptTally()
    await stateLedger?.promptEnded(idle, started: false)
  }

  /// Ends each prompt that a `session/cancel` reached when the `signalDone`
  /// of its `cancelForeground()` signal comes.
  /// It keeps the id of each other signal for a
  /// ``SessionProjector/Input/cancelSent(_:)`` that comes later.
  ///
  /// - Parameter signal: The id of the signal that ended.
  private mutating func signalDone(_ signal: SignalID) async {
    if pendingCancels.remove(signal) != nil {
      await endCancelledPrompts()
      return
    }
    recentSignalsDone.append(signal)
    if recentSignalsDone.count > Self.recentSignalsDoneLimit {
      recentSignalsDone.removeFirst()
    }
  }

  /// Ends each open prompt that a `session/cancel` reached, as
  /// `cancelled`. A prompt that opened after the cancel stays open.
  private mutating func endCancelledPrompts() async {
    for prompt in open.map(\.prompt) {
      if await prompt.owner.cancelRequested {
        await endPrompt(prompt.mailId, stop: .cancelled)
      }
    }
  }

  /// The handler that starts each elicitation round trip in its own task
  /// (elicitation-plan task 5).
  /// So the translation does not wait for the user.
  /// It is `nil` when no relay is wired or the source has no session.
  ///
  /// - Parameter session: The Router session that the answer goes back to.
  /// - Returns: The handler.
  private func relayHandler(
    for session: (any RoutedSession)?
  ) -> ElicitationEventHandler? {
    guard let relay, let session else {
      return nil
    }
    return { event in
      Task {
        await relay.relay(event, on: session)
      }
    }
  }

  /// The stop of `prompt` when `event` is the terminal event of its mail,
  /// or `nil` for each other event.
  ///
  /// A failed answer gives its typed error through `awaitAnswer(of:)`.
  /// The terminal is already in the ledger of the session when the event comes.
  /// So the call returns at once (task ^9xs24pn, decision G5).
  ///
  /// - Parameters:
  ///   - event: The event.
  ///   - prompt: The open prompt.
  ///   - sessionId: The id of the ACP session, for the log of a failure.
  ///   - parent: The id of the parent of the session, or `nil` for a root session.
  /// - Returns: The stop, or `nil`.
  private static func stop(
    of event: SessionEvent, ending prompt: SessionProjector.Prompt, sessionId: SessionId,
    parent: SessionId?
  ) async -> PromptStop? {
    let mailId = prompt.mailId
    switch event {
    case .answered(let answer) where answer.mailIds.contains(mailId):
      return .completed
    case .answerFailed(let failure) where failure.mailIds.contains(mailId):
      if case .cancelled = failure.reason {
        return .cancelled
      }
      do {
        _ = try await prompt.awaitAnswer(mailId)
        return .completed
      } catch {
        let stop = PromptExecution.classify(error)
        if case .failed = stop {
          PromptExecution.report(
            failure: error, sessionId: sessionId, parent: parent, modelName: prompt.modelName)
        }
        return stop
      }
    case .cancelled(let id) where id == mailId:
      return .cancelled
    case .lost(let id) where id == mailId:
      return .failed(message: "the session lost the prompt")
    default:
      return nil
    }
  }

  /// Ends each open prompt with `stop`: the end of the inbox.
  ///
  /// - Parameter stop: Why the prompts stopped.
  mutating func endOpenPrompts(stop: PromptStop) async {
    for prompt in open.map(\.prompt) {
      await endPrompt(prompt.mailId, stop: stop)
    }
  }

  /// Ends the open prompt of the mail `mailId` with `stop`, or does
  /// nothing when no such prompt is open.
  /// The steps are these.
  /// First, the cut and the empty checks of a completed prompt.
  /// Then the close of each tool call that did not finish.
  /// Then the one `usage_update`.
  /// Then the end of the prompt in its owner (the
  /// `idle` when no other prompt is open).
  /// Last, the end work of the prompt.
  ///
  /// - Parameters:
  ///   - mailId: The mail of the prompt.
  ///   - stop: Why the prompt stopped.
  private mutating func endPrompt(_ mailId: MailID, stop: PromptStop) async {
    guard let index = open.firstIndex(where: { $0.prompt.mailId == mailId }) else {
      return
    }
    let ending = open.remove(at: index)
    var stop = stop
    // A cancelled prompt does not always end with a cancelled terminal.
    // Model work that never checks for cancellation runs to completion.
    // The recorded request still ends the prompt as cancelled.
    if await ending.prompt.owner.cancelRequested {
      stop = .cancelled
    }
    // A completed prompt must not read as a normal `end_turn` in one case.
    // The case is no output and a usage report that says zero generated tokens (task
    // ^pez780d).
    if stop == .completed, ending.tally.generatedNothing {
      stop = .noOutput
    }
    // A completed prompt whose LAST submission did not end by itself is
    // cut, not finished (tasks ^bw9qt1z, ^k51h6bb and ^7fsfw7y).
    if stop == .completed, let cut = PromptExecution.cutStop(for: ending.tally.lastFinishReason) {
      stop = cut
      PromptExecution.report(
        cut: cut, metadata: ending.tally.cutMetadata,
        changedFileCount: ending.tally.changedFileCount,
        sessionId: translator.sessionId, parent: translator.parentSessionId,
        modelName: ending.prompt.modelName)
    }
    if let status = PromptExecution.closingStatus(for: stop) {
      for toolCallId in await ending.toolCalls.unfinishedToolCallIds() {
        await send(.toolCallUpdate(ToolCallUpdate(toolCallId: toolCallId, status: .value(status))))
      }
    }
    if let usage = ending.tally.usageUpdate {
      await send(.usageUpdate(usage))
    }
    let reason = await ending.prompt.owner.promptDidEnd(stop: stop)
    await ending.prompt.onEnd(reason)
  }
}

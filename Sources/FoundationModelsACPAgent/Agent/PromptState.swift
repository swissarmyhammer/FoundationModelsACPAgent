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

/// The `state_update` of one ACP session: `running` while the session is
/// busy, and `idle` when it is not busy any more (elicitation-plan task 2).
///
/// The session is busy while Router works (``workStarted(on:)`` and
/// ``workEnded(on:)``) or a prompt is open. Router work is an open
/// background run, an answer that runs, or queued run mail. A run that waits
/// only for the user is no work, so an open question does not keep the
/// session busy. A prompt counts too, because some prompts make no Router
/// work: a slash command with no model pass, a refused mail, and a prompt
/// cancelled before its mail went in. More than one Router session can feed
/// the session (the replacement session of a model slot switch), so the
/// ledger keeps the set of the sessions that work.
///
/// An `idle` carries the stop reason and the error of the last prompt that
/// ended since the last `running`. When only background work ran since the
/// last `running`, the `idle` has no stop reason. A prompt that ends while
/// Router still works sends no `idle`: the `idle` comes when the work ends.
actor SessionStateLedger {
    /// The sink every state update goes to.
    private let send: SessionUpdateSink

    /// The number of prompts that started and did not end.
    private var openCount = 0

    /// The ids of the Router sessions that work now.
    private var workingSources: Set<ULID> = []

    /// Whether the last state update was `running`.
    private var sentRunning = false

    /// The `idle` of the last prompt that ended since the last `running`,
    /// or `nil` when no prompt ended since then.
    private var lastPromptEnd: IdleStateUpdate?

    /// Creates the ledger over `send`.
    ///
    /// - Parameter send: The sink every state update goes to.
    init(send: @escaping SessionUpdateSink) {
        self.send = send
    }

    /// Whether a prompt is open now.
    var hasOpenPrompt: Bool {
        openCount > 0
    }

    /// Whether the session is busy: Router works, or a prompt is open.
    private var isBusy: Bool {
        openCount > 0 || !workingSources.isEmpty
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
        if !started, !isBusy, !sentRunning {
            lastPromptEnd = nil
            await send(.stateUpdate(.idle(idle.sayingNoWork())))
            return
        }
        await sendChange()
    }

    /// Records that the Router session `source` has work now
    /// (`SessionEvent.workStarted`).
    ///
    /// - Parameter source: The id of the Router session.
    func workStarted(on source: ULID) async {
        workingSources.insert(source)
        await sendChange()
    }

    /// Records that the Router session `source` has no work now
    /// (`SessionEvent.workEnded`), or that its feed ended: Router sends no
    /// work event after `close()` starts.
    ///
    /// - Parameter source: The id of the Router session.
    func workEnded(on source: ULID) async {
        workingSources.remove(source)
        await sendChange()
    }

    /// Sends `running` when the session became busy, and `idle` when it is
    /// not busy any more.
    private func sendChange() async {
        if isBusy, !sentRunning {
            sentRunning = true
            lastPromptEnd = nil
            await send(.stateUpdate(.running(RunningStateUpdate())))
        } else if !isBusy, sentRunning {
            sentRunning = false
            let idle = lastPromptEnd ?? IdleStateUpdate()
            lastPromptEnd = nil
            await send(.stateUpdate(.idle(idle.sayingNoWork())))
        }
    }
}

/// The prompt-state owner of one prompt.
///
/// It gives the transitions of its prompt to the ``SessionStateLedger`` of
/// the session: the start and the end with a stop reason. The ledger
/// decides which state update goes out, because more than one prompt can be
/// open and Router work keeps the session busy too. The agent never sends
/// `requires_action`: a run that waits only for the user is no work
/// (elicitation-plan section 8).
/// It also records a `session/cancel` request, so the prompt ends as
/// `cancelled` even when the cancelled model work runs to completion:
/// model work that never checks for cancellation returns its response,
/// and does not throw.
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

    /// The handlers that ``noteCancelRequested()`` runs, one time each
    /// (``onCancelRequest(_:)``).
    private var cancelHandlers: [@Sendable () -> Void] = []

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
    /// completion. It also runs each handler that
    /// ``onCancelRequest(_:)`` registered.
    func noteCancelRequested() {
        cancelRequested = true
        let handlers = cancelHandlers
        cancelHandlers = []
        for handler in handlers {
            handler()
        }
    }

    /// Runs `handler` when `session/cancel` asks this prompt to stop: at
    /// once when the request is already recorded, else at the request. A
    /// prompt that waits for the work of its session (task ^64pav2a)
    /// registers the cancel of that wait here, so the cancel ends the wait
    /// at once.
    ///
    /// - Parameter handler: The work to run at the request.
    func onCancelRequest(_ handler: @escaping @Sendable () -> Void) {
        guard !cancelRequested else {
            handler()
            return
        }
        cancelHandlers.append(handler)
    }
}

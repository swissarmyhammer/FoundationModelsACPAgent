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

/// The `state_update` of one ACP session, over all its open prompts.
///
/// More than one prompt can be open at the same time (no busy gate;
/// elicitation-plan task 3). The session sends `running` when the first
/// prompt starts, and `idle` with the stop reason of the prompt that ends
/// last, when no prompt is open any more. While no prompt is open, the
/// session sends no state update (task ^9xs24pn, decision Q2). Running and
/// idle from Router work are elicitation-plan tasks 2 and 10.
actor SessionStateLedger {
    /// The sink every state update goes to.
    private let send: SessionUpdateSink

    /// The number of prompts that started and did not end.
    private var openCount = 0

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

    /// Counts one more open prompt, and sends `running` when it is the only
    /// open prompt.
    func promptStarted() async {
        openCount += 1
        if openCount == 1 {
            await send(.stateUpdate(.running(RunningStateUpdate())))
        }
    }

    /// Counts one prompt less, and sends `idle` when no prompt is open any
    /// more.
    ///
    /// - Parameters:
    ///   - idle: The `idle` of the prompt that ends.
    ///   - started: Whether the prompt started (``promptStarted()``). A
    ///     prompt that ends before its start counts nothing, but it still
    ///     sends its `idle` when no other prompt is open.
    func promptEnded(_ idle: IdleStateUpdate, started: Bool) async {
        if started {
            openCount -= 1
        }
        if openCount == 0 {
            await send(.stateUpdate(.idle(idle)))
        }
    }

    /// Sends `requires_action` for a wait on the human, while a prompt is
    /// open.
    func awaitingUser() async {
        guard openCount > 0 else { return }
        await send(.stateUpdate(.requiresAction(RequiresActionStateUpdate())))
    }

    /// Sends `running` after a wait on the human, while a prompt is open.
    func userAnswered() async {
        guard openCount > 0 else { return }
        await send(.stateUpdate(.running(RunningStateUpdate())))
    }
}

/// The prompt-state owner of one prompt.
///
/// It gives the transitions of its prompt to the ``SessionStateLedger`` of
/// the session: the start, a wait on the human (`requires_action`, then
/// `running` at the answer), and the end with a stop reason. The ledger
/// decides which state update goes out, because more than one prompt can be
/// open.
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

    /// Runs `body` as a wait on the human, for example an elicitation
    /// round trip. A prompt that stays `running` while it waits on a
    /// person shows as a stopped agent. Thus this call sends
    /// `requires_action`, runs the body, and returns to `running` when the
    /// body ends — with a value or with an error.
    ///
    /// The wait is an ACP state only. Router has no call for it: its
    /// generation queue gives a wait for a person no release of the model.
    ///
    /// The round trip runs in its own task, so the prompt can end before the
    /// body ends, for example at a cancel. After the `idle` of the prompt,
    /// no state update of the wait goes out.
    ///
    /// - Parameter body: The wait on the human.
    /// - Returns: The body's value.
    /// - Throws: The body's error, after the state returns to `running`.
    func awaitingUser<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        if stopReason == nil {
            await ledger.awaitingUser()
        }
        do {
            let value = try await body()
            await sendRunning()
            return value
        } catch {
            await sendRunning()
            throw error
        }
    }

    /// Ends the prompt with `stop`: the ledger sends the `idle` with the
    /// stop reason, and with the `error` object of a failed prompt
    /// (``PromptExecution/idleState(for:)``), when no other prompt is open.
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

    /// Sends `state_update: running` after a wait on the human, but not
    /// after the end of the prompt.
    private func sendRunning() async {
        guard stopReason == nil else {
            return
        }
        await ledger.userAnswered()
    }
}

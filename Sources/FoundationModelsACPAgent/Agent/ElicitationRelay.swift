import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import os

/// The logger of the elicitation relay: the round trips, the declines, and
/// the dropped late answers.
private let relayLogger = Logger(
    subsystem: RoutedACPAgent.implementation.name, category: "ElicitationRelay")

/// The consumer of one live elicitation request event. The production
/// handler is the bound ``ElicitationRelay``; a synthetic projection test
/// wires none.
typealias ElicitationEventHandler = @Sendable (OperationEvent) async -> Void

/// The relay of a tool's elicitation to the ACP client (plan.md §16).
///
/// A tool that calls `ToolContext.elicit` suspends in Router's mailbox, and
/// the request arrives as `SessionEvent.elicitationRequested`. This actor
/// turns that event into one `elicitation/create` on the wire, decodes the
/// client's answer, and delivers it back through
/// `RoutedSession.respond(elicitationId:response:)`. Each round trip runs
/// inside ``TurnStateOwner/awaitingUser(on:_:)``, so the wire shows
/// `requires_action` before the question and `running` after the answer
/// (plan.md §8.2).
///
/// The capability gate (plan.md §16): the client said what it answers at
/// `initialize`. An absent capability, or an absent mode object, means
/// unsupported. A request in an unsupported mode gets `decline` at Router,
/// and no `elicitation/create` goes out. The relay never falls back from
/// `url` mode to `form` mode. Extras' `ElicitationResponse` carries no
/// reason field, so the reason for a decline goes to the log only.
///
/// The security duties (plan.md §16): a URL-mode accept never carries
/// content back over ACP — the flow returns its data out of band. The
/// `elicitationId` stays unique among the outstanding URL elicitations on
/// the connection; a duplicate gets `decline`. The `elicitation/complete`
/// notification goes only through the one connection that received the
/// create — this actor holds exactly that connection.
actor ElicitationRelay {
    /// The id of the session this relay serves, for the wire scope and the
    /// log lines.
    private let sessionId: SessionId

    /// The client's negotiated capabilities, read at `initialize`.
    private let capabilities: NegotiatedClientCapabilities

    /// The one connection the create, and a later completion, go through.
    private let connection: AgentSideConnection

    /// The waiters of the round trips in flight, keyed by the elicitation
    /// id. ``cancelPendingElicitations()`` resumes each with `cancel`.
    private var pendingAnswers: [String: CheckedContinuation<ElicitationResponse, Never>] = [:]

    /// The tasks that carry the wire requests in flight, keyed by the
    /// elicitation id. ``cancelPendingElicitations()`` cancels them.
    private var answerTasks: [String: Task<Void, Never>] = [:]

    /// The ids of the outstanding URL-mode elicitations, for the
    /// uniqueness duty.
    private var outstandingURLElicitationIds: Set<String> = []

    /// Creates a relay for one session over one bound connection.
    ///
    /// - Parameters:
    ///   - sessionId: The session this relay serves.
    ///   - capabilities: The client's capabilities from `initialize`.
    ///   - connection: The connection the wire messages go through.
    init(
        sessionId: SessionId,
        capabilities: NegotiatedClientCapabilities,
        connection: AgentSideConnection
    ) {
        self.sessionId = sessionId
        self.capabilities = capabilities
        self.connection = connection
    }

    // MARK: - The round trip

    /// Relays one elicitation event: the capability gate, the wire round
    /// trip inside the turn's `awaitingUser`, and the answer delivery
    /// through `session.respond(elicitationId:response:)`.
    ///
    /// - Parameters:
    ///   - event: The `.elicitation` operation event the session posted.
    ///   - session: The Router session the answer goes back to.
    ///   - turnState: The turn-state owner that pairs `requires_action`
    ///     with `running` around the wait.
    func relay(
        _ event: OperationEvent,
        on session: any RoutedSession,
        turnState: TurnStateOwner
    ) async {
        // The "elicitation is non-nil iff the kind is .elicitation" rule
        // is a doc comment upstream, not a type guarantee; read it
        // defensively, the way the settlement projection does.
        guard let request = event.elicitation else {
            relayLogger.warning(
                "session \(self.sessionId.rawValue, privacy: .public): run \(event.correlationID, privacy: .public) posted an elicitation event with no request; ignored"
            )
            return
        }
        let elicitationId = request.elicitationId.ulidString
        guard supports(request.mode) else {
            await decline(
                elicitationId: elicitationId, on: session,
                reason: Self.unsupportedModeReason(for: request.mode))
            return
        }
        guard
            let wireRequest = Self.wireRequest(
                for: request, sessionId: sessionId, toolCallId: event.correlationID)
        else {
            await decline(
                elicitationId: elicitationId, on: session, reason: Self.missingPayloadReason)
            return
        }
        guard beginURLFlowIfNeeded(mode: request.mode, elicitationId: elicitationId) else {
            await decline(
                elicitationId: elicitationId, on: session, reason: Self.duplicateURLIdReason)
            return
        }
        await turnState.awaitingUser(on: session) {
            await self.deliverRoundTrip(
                wireRequest, elicitationId: elicitationId, mode: request.mode, on: session)
        }
        endURLFlowIfNeeded(mode: request.mode, elicitationId: elicitationId)
    }

    /// Answers every round trip still in flight with `cancel`, so each
    /// suspended tool resumes before the turn's `idle` terminator.
    /// `session/cancel` and `session/close` call it (plan.md §8.6, §10.1).
    ///
    /// The tasks that still wait on the client are cancelled too. An
    /// answer that arrives after this call finds no waiter and is
    /// dropped.
    func cancelPendingElicitations() {
        for task in answerTasks.values {
            task.cancel()
        }
        answerTasks = [:]
        let waiting = pendingAnswers
        pendingAnswers = [:]
        for continuation in waiting.values {
            continuation.resume(returning: .cancel)
        }
    }

    /// Runs one wire round trip and delivers the answer to Router: the
    /// create, the decode, the `respond`, and — for an accepted URL-mode
    /// flow — the completion.
    ///
    /// - Parameters:
    ///   - wireRequest: The mapped `elicitation/create` request.
    ///   - elicitationId: The pending elicitation's id.
    ///   - mode: The mode of the request.
    ///   - session: The Router session the answer goes back to.
    private func deliverRoundTrip(
        _ wireRequest: CreateElicitationRequest,
        elicitationId: String,
        mode: ElicitationMode,
        on session: any RoutedSession
    ) async {
        let answer = await clientAnswer(to: wireRequest, elicitationId: elicitationId, mode: mode)
        let delivery = await session.respond(elicitationId: elicitationId, response: answer)
        switch delivery {
        case .delivered:
            break
        case .acceptedAwaitingCompletion:
            await completeURLFlow(elicitationId: elicitationId, on: session)
        case .noPendingElicitation:
            relayLogger.warning(
                "session \(self.sessionId.rawValue, privacy: .public): elicitation \(elicitationId, privacy: .public) had no pending entry at Router; the answer was dropped"
            )
        @unknown default:
            relayLogger.debug(
                "session \(self.sessionId.rawValue, privacy: .public): elicitation \(elicitationId, privacy: .public) delivery \(String(describing: delivery), privacy: .public)"
            )
        }
    }

    /// Sends the create and suspends until the client answers or
    /// ``cancelPendingElicitations()`` resolves the wait with `cancel`.
    ///
    /// The wire request runs on its own task: a JSON-RPC request has no
    /// revoke, so a cancelled round trip must not stay suspended on it.
    /// The task is stored and cancelled at ``cancelPendingElicitations()``,
    /// and a late answer finds no waiter and is dropped.
    ///
    /// - Parameters:
    ///   - wireRequest: The mapped `elicitation/create` request.
    ///   - elicitationId: The pending elicitation's id.
    ///   - mode: The mode of the request.
    /// - Returns: The decoded answer, or `cancel`.
    private func clientAnswer(
        to wireRequest: CreateElicitationRequest, elicitationId: String, mode: ElicitationMode
    ) async -> ElicitationResponse {
        await withCheckedContinuation { continuation in
            pendingAnswers[elicitationId] = continuation
            answerTasks[elicitationId] = Task {
                let raw: CreateElicitationResponse?
                do {
                    raw = try await connection.createElicitation(wireRequest)
                } catch {
                    relayLogger.warning(
                        "session \(self.sessionId.rawValue, privacy: .public): elicitation/create failed: \(error, privacy: .public)"
                    )
                    raw = nil
                }
                self.deliver(Self.answer(from: raw, mode: mode), toPending: elicitationId)
            }
        }
    }

    /// Resumes the round trip waiting on `elicitationId` with `answer`. A
    /// late answer — one that arrives after the wait was cancelled —
    /// finds no waiter and is dropped.
    ///
    /// - Parameters:
    ///   - answer: The decoded answer.
    ///   - elicitationId: The pending elicitation's id.
    private func deliver(_ answer: ElicitationResponse, toPending elicitationId: String) {
        answerTasks.removeValue(forKey: elicitationId)
        guard let continuation = pendingAnswers.removeValue(forKey: elicitationId) else {
            relayLogger.debug(
                "session \(self.sessionId.rawValue, privacy: .public): a late answer for elicitation \(elicitationId, privacy: .public) was dropped"
            )
            return
        }
        continuation.resume(returning: answer)
    }

    /// Ends an accepted URL-mode flow: the `elicitation/complete`
    /// notification goes to the one client that received the create —
    /// this relay holds exactly that connection — and only then
    /// `session.complete(elicitationId:)` resumes the tool.
    ///
    /// - Parameters:
    ///   - elicitationId: The accepted elicitation's id.
    ///   - session: The Router session whose flow completes.
    private func completeURLFlow(elicitationId: String, on session: any RoutedSession) async {
        do {
            try await connection.elicitationComplete(
                CompleteElicitationNotification(
                    elicitationId: ElicitationId(rawValue: elicitationId)))
        } catch {
            relayLogger.warning(
                "session \(self.sessionId.rawValue, privacy: .public): elicitation/complete send failed: \(error, privacy: .public)"
            )
        }
        await session.complete(elicitationId: elicitationId)
    }

    // MARK: - The capability gate

    /// Whether the client answers requests in `mode`. Absent means
    /// unsupported, and `url` never falls back to `form`.
    ///
    /// - Parameter mode: The requested mode.
    /// - Returns: Whether the mode is supported.
    private func supports(_ mode: ElicitationMode) -> Bool {
        switch mode {
        case .form:
            capabilities.supportsFormElicitation
        case .url:
            capabilities.supportsURLElicitation
        }
    }

    /// Answers Router with `decline`. Extras' response carries no reason
    /// field, so `reason` goes to the log only; the tool sees the bare
    /// decline. No `elicitation/create` goes out on this path.
    ///
    /// - Parameters:
    ///   - elicitationId: The pending elicitation's id.
    ///   - session: The Router session the decline goes to.
    ///   - reason: Why the relay declined, for the log.
    private func decline(
        elicitationId: String, on session: any RoutedSession, reason: String
    ) async {
        relayLogger.notice(
            "session \(self.sessionId.rawValue, privacy: .public): elicitation \(elicitationId, privacy: .public) declined: \(reason, privacy: .public)"
        )
        await session.respond(elicitationId: elicitationId, response: .decline)
    }

    /// The decline reason for a mode the client does not answer.
    ///
    /// - Parameter mode: The unsupported mode.
    /// - Returns: The reason text.
    private static func unsupportedModeReason(for mode: ElicitationMode) -> String {
        "the client does not advertise the \(mode.rawValue) elicitation capability"
    }

    /// The decline reason for a request without its mode's payload.
    private static let missingPayloadReason =
        "the request does not carry its mode's payload"

    /// The decline reason for a URL-mode id that is already outstanding.
    private static let duplicateURLIdReason =
        "the elicitationId is already outstanding on this connection"

    // MARK: - The URL-mode uniqueness duty

    /// Registers a URL-mode flow, or refuses a duplicate id: the
    /// `elicitationId` stays unique among the outstanding URL
    /// elicitations on the connection (plan.md §16). A form-mode request
    /// registers nothing.
    ///
    /// - Parameters:
    ///   - mode: The requested mode.
    ///   - elicitationId: The pending elicitation's id.
    /// - Returns: Whether the round trip can start.
    private func beginURLFlowIfNeeded(mode: ElicitationMode, elicitationId: String) -> Bool {
        guard mode == .url else {
            return true
        }
        return outstandingURLElicitationIds.insert(elicitationId).inserted
    }

    /// Releases a URL-mode flow's id. A form-mode request releases
    /// nothing.
    ///
    /// - Parameters:
    ///   - mode: The requested mode.
    ///   - elicitationId: The elicitation's id.
    private func endURLFlowIfNeeded(mode: ElicitationMode, elicitationId: String) {
        guard mode == .url else {
            return
        }
        outstandingURLElicitationIds.remove(elicitationId)
    }

    // MARK: - The wire mapping

    /// Maps Extras' request to the wire request, scoped by the session and
    /// the run's tool call (plan.md §11.8: the run's `completionToken` is
    /// its `toolCallId`).
    ///
    /// - Parameters:
    ///   - request: The request the tool posted.
    ///   - sessionId: The session the elicitation belongs to.
    ///   - toolCallId: The run's completion token.
    /// - Returns: The wire request, or `nil` when the request does not
    ///   carry its mode's payload.
    static func wireRequest(
        for request: ElicitationRequest, sessionId: SessionId, toolCallId: String
    ) -> CreateElicitationRequest? {
        let scope = ElicitationSessionScope(
            sessionId: sessionId, toolCallId: ToolCallId(rawValue: toolCallId))
        switch request.mode {
        case .form:
            guard let requestedSchema = request.requestedSchema,
                let wireSchema = wireSchema(of: requestedSchema)
            else {
                return nil
            }
            return CreateElicitationRequest(
                message: request.message,
                mode: .form(ElicitationFormMode(requestedSchema: wireSchema, scope: .session(scope))))
        case .url:
            guard let url = request.url else {
                return nil
            }
            return CreateElicitationRequest(
                message: request.message,
                mode: .url(
                    ElicitationUrlMode(
                        elicitationId: ElicitationId(rawValue: request.elicitationId.ulidString),
                        url: url.absoluteString,
                        scope: .session(scope))))
        }
    }

    /// Decodes the client's raw answer into Extras' response.
    ///
    /// An answer this relay cannot read delivers `cancel`, never a guess:
    /// the tool must not receive an accept whose content was lost. A
    /// URL-mode accept always carries `nil` content — the flow returns its
    /// data out of band, never over ACP (plan.md §16, the security duty).
    ///
    /// - Parameters:
    ///   - raw: The raw wire answer, or `nil` when the request failed.
    ///   - mode: The mode of the request the answer belongs to.
    /// - Returns: The response to deliver to Router.
    static func answer(
        from raw: CreateElicitationResponse?, mode: ElicitationMode
    ) -> ElicitationResponse {
        guard let raw,
            let encoded = try? JSONEncoder().encode(raw),
            let decoded = try? JSONDecoder().decode(WireAnswer.self, from: encoded)
        else {
            relayLogger.warning("an elicitation answer did not decode; delivering cancel")
            return .cancel
        }
        switch decoded.action {
        case .accept:
            return .accept(content: mode == .form ? decoded.content : nil)
        case .decline:
            return .decline
        case .cancel:
            return .cancel
        }
    }

    /// The wire shape of the client's answer. Extras' own decoders read
    /// the action and the content values, so an unknown action or an
    /// undecodable content value fails the decode as a whole.
    private struct WireAnswer: Decodable {
        /// How the user answered.
        let action: ElicitationResponse.Action

        /// The filled form values, or `nil`.
        let content: [String: ElicitationValue]?
    }

    /// Bridges Extras' restricted schema to the wire schema: Extras
    /// encodes the exact JSON object shape the wire type decodes.
    ///
    /// - Parameter schema: The schema the tool requested.
    /// - Returns: The wire schema, or `nil` when the bridge fails.
    private static func wireSchema(of schema: ElicitationRequestedSchema) -> ElicitationSchema? {
        guard let encoded = try? JSONEncoder().encode(schema) else {
            return nil
        }
        return try? JSONDecoder().decode(ElicitationSchema.self, from: encoded)
    }
}

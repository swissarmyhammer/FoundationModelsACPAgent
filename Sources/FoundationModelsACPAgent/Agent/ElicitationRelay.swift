import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Logging
import Tracing

/// The consumer of one live elicitation request event. The production
/// handler is the bound ``ElicitationRelay``; a synthetic projection test
/// wires none.
typealias ElicitationEventHandler = @Sendable (OperationEvent) async -> Void

/// The consumer of the end of one question that Router ended with no answer
/// of the client. The production handler is ``ElicitationRelay/end(_:)``; a
/// synthetic projection test wires none.
typealias ElicitationEndHandler = @Sendable (ElicitationEnd) async -> Void

/// The relay of a tool's elicitation to the ACP client. This package owns
/// elicitation, because it is the only layer with a live two-way channel
/// to a user. An elicitation asks a question that a tool needs answered.
/// It is not a permission prompt, and it authorizes nothing.
///
/// A tool that calls `ToolContext.elicit` suspends in Router's mailbox, and
/// the request arrives as `SessionEvent.elicitationRequested`. This actor
/// changes that event into one `elicitation/create` on the wire, decodes the
/// client's answer, and delivers it back through
/// `RoutedSession.respond(elicitationId:response:)`. The relay lives as long
/// as the session (elicitation-plan task 4), and the ``SessionProjector``
/// runs each round trip in its own task, so a question does not stop the
/// other output of the session (task 5). While a prompt is open, the round
/// trip runs inside ``PromptStateOwner/awaitingUser(_:)``, so the wire shows
/// `requires_action` before the question and `running` after the answer.
///
/// Router ends a question with no answer of the client when it stops the run
/// of the question: a cancel of the run, `cancelAll()` and `close()`. It then
/// sends `SessionEvent.elicitationEnded`, and ``end(_:)`` ends the client
/// request: the relay cancels the task of the `elicitation/create`, and the
/// connection sends `$/cancel_request` for it (gap ^crjmk34).
///
/// The capability gate: the client said what it answers at
/// `initialize`. An absent capability, or an absent mode object, means
/// unsupported. A request in an unsupported mode gets `decline` at Router,
/// and no `elicitation/create` goes out. The relay never falls back from
/// `url` mode to `form` mode. A decline of the relay carries its reason
/// (``DeclineReason``), so the tool and the model see why.
///
/// The ACP security duties: a URL-mode accept never carries
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
    ///
    /// The relay lives as long as the session, and the agent keeps the
    /// session, so the relay keeps the connection weakly, as the history sink
    /// does (task `^173qn8n`): the connection keeps the agent. When the
    /// connection is gone, a round trip gets `cancel`.
    private weak var connection: AgentSideConnection?

    /// How the wait of one round trip ended.
    private enum ClientAnswer {
        /// The client answered, or the wire request failed and the relay
        /// gives `cancel`.
        case answered(ElicitationResponse)

        /// Router ended the question with no answer of the client. Router
        /// already gave the run its response, so the relay does not
        /// respond.
        case ended(ElicitationEnd)
    }

    /// The waiters of the round trips in flight, keyed by the elicitation
    /// id. ``end(_:)`` and ``drainOpenRoundTrips()`` resume them.
    private var pendingAnswers: [String: CheckedContinuation<ClientAnswer, Never>] = [:]

    /// The tasks that carry the wire requests in flight, keyed by the
    /// elicitation id. ``end(_:)`` and ``drainOpenRoundTrips()`` cancel
    /// them.
    private var answerTasks: [String: Task<Void, Never>] = [:]

    /// The ends of questions whose round trip did not wait yet, keyed by
    /// the elicitation id. The projector starts each round trip in its own
    /// task, so the end of a question can come to the relay before the
    /// round trip. Such a round trip sends no create.
    private var earlyEnds: [String: ElicitationEnd] = [:]

    /// The waits of ``end(_:)`` for the finish of the round trips that it
    /// ended, keyed by the elicitation id. A round trip resumes them at its
    /// finish, after the `running` of the open prompt went out.
    private var finishWaits: [String: [CheckedContinuation<Void, Never>]] = [:]

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
    /// trip, inside the `awaitingUser` of the open prompt when one is open,
    /// and the answer delivery through
    /// `session.respond(elicitationId:response:)`.
    ///
    /// The relay of a request runs in one elicitation span
    /// (``AgentTracing``). The span carries the mode and the outcome:
    /// `accept`, `decline` or `cancel`. A decline of the relay itself is a
    /// `decline` outcome too. The span waits for the user, so it writes one
    /// "enter" record when it opens. The span and the record never carry
    /// the message, the schema or the answer content.
    ///
    /// - Parameters:
    ///   - event: The `.elicitation` operation event the session posted.
    ///   - session: The Router session the answer goes back to.
    ///   - promptState: The prompt-state owner of the open prompt, which
    ///     pairs `requires_action` with `running` around the wait, or `nil`
    ///     while no prompt is open: then no state update goes out.
    func relay(
        _ event: OperationEvent,
        on session: any RoutedSession,
        promptState: PromptStateOwner?
    ) async {
        // The "elicitation is non-nil iff the kind is .elicitation" rule
        // is a doc comment upstream, not a type guarantee; read it
        // defensively, the way the settlement projection does.
        guard let request = event.elicitation else {
            var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
            metadata[ACPAgentTelemetry.LogMetadataKey.toolCallId] = "\(event.correlationID)"
            ACPAgentTelemetry.logger(.elicitationRelay).warning(
                "An elicitation event has no request. The relay ignores the event.",
                metadata: metadata)
            return
        }
        // `TracedCall.run` is not `rethrows`. This body does not throw, thus
        // `try?` discards no error.
        try? await AgentTracing.withEnteredSpan(
            ACPAgentTelemetry.SpanName.elicitation,
            logger: ACPAgentTelemetry.logger(.elicitationRelay),
            attributes: { $0[ACPAgentTelemetry.AttributeKey.elicitationMode] = request.mode.rawValue },
            metadata: elicitationMetadata(request.elicitationId.ulidString)
        ) { span in
            let outcome = await relayRequest(
                request, toolCallId: event.correlationID, on: session, promptState: promptState)
            span.attributes[ACPAgentTelemetry.AttributeKey.elicitationOutcome] = outcome.action.rawValue
            if let reason = outcome.reason {
                span.attributes[ACPAgentTelemetry.AttributeKey.elicitationEndReason] = reason
            }
        }
    }

    /// Relays one elicitation request: the work of
    /// ``relay(_:on:promptState:)`` in the elicitation span.
    ///
    /// - Parameters:
    ///   - request: The request the tool posted.
    ///   - toolCallId: The run's completion token.
    ///   - session: The Router session the answer goes back to.
    ///   - promptState: The prompt-state owner of the open prompt, or `nil`
    ///     while no prompt is open.
    /// - Returns: How the elicitation ended: the answer that went to Router,
    ///   or the response of the end that Router sent.
    private func relayRequest(
        _ request: ElicitationRequest,
        toolCallId: String,
        on session: any RoutedSession,
        promptState: PromptStateOwner?
    ) async -> ElicitationResponse {
        let elicitationId = request.elicitationId.ulidString
        guard supports(request.mode) else {
            await decline(
                elicitationId: elicitationId, mode: request.mode, on: session,
                reason: .unsupportedMode)
            return .decline
        }
        guard
            let wireRequest = Self.wireRequest(
                for: request, sessionId: sessionId, toolCallId: toolCallId)
        else {
            await decline(
                elicitationId: elicitationId, mode: request.mode, on: session,
                reason: .missingPayload)
            return .decline
        }
        guard beginURLFlowIfNeeded(mode: request.mode, elicitationId: elicitationId) else {
            await decline(
                elicitationId: elicitationId, mode: request.mode, on: session,
                reason: .duplicateURLElicitationId)
            return .decline
        }
        let roundTrip = { @Sendable in
            await self.deliverRoundTrip(
                wireRequest, elicitationId: elicitationId, mode: request.mode, on: session)
        }
        let outcome = if let promptState {
            await promptState.awaitingUser(roundTrip)
        } else {
            await roundTrip()
        }
        endURLFlowIfNeeded(mode: request.mode, elicitationId: elicitationId)
        earlyEnds.removeValue(forKey: elicitationId)
        for wait in finishWaits.removeValue(forKey: elicitationId) ?? [] {
            wait.resume()
        }
        return outcome
    }

    /// Ends the client request of a question that Router ended with no
    /// answer of the client: the relay cancels the task of the
    /// `elicitation/create`, so the connection sends `$/cancel_request`, and
    /// the round trip ends with the response of `end`. The round trip does
    /// not respond to Router: Router already gave the run that response.
    ///
    /// The call returns when the round trip finished: the state update of
    /// the open prompt after the wait went out. Thus the projector, which
    /// waits for this call, sends the next event of the session after that
    /// update, for example the `idle` of a cancelled prompt.
    ///
    /// The wire request has no field for the reason, so the reason goes to
    /// the log record and to the elicitation span. An end whose round trip
    /// does not wait yet is kept, and that round trip sends no create.
    ///
    /// - Parameter end: The end that Router sent.
    func end(_ end: ElicitationEnd) async {
        let elicitationId = end.elicitationId.ulidString
        guard let continuation = pendingAnswers.removeValue(forKey: elicitationId) else {
            earlyEnds[elicitationId] = end
            ACPAgentTelemetry.logger(.elicitationRelay).debug(
                "Router ended a question that has no client request in flight. The relay keeps the end.",
                metadata: endMetadata(end))
            return
        }
        answerTasks.removeValue(forKey: elicitationId)?.cancel()
        ACPAgentTelemetry.logger(.elicitationRelay).notice(
            "Router ended a question with no answer of the client. The relay ended the client request.",
            metadata: endMetadata(end))
        await withCheckedContinuation { finished in
            finishWaits[elicitationId, default: []].append(finished)
            continuation.resume(returning: .ended(end))
        }
    }

    /// Ends each round trip that is still in flight when the feed of the
    /// session ended, with `cancel`, and stops its wire request. The
    /// projector calls it at the end of its feed.
    ///
    /// Router sends `elicitationEnded` for each question that a cancel of a
    /// run, `cancelAll()` or `close()` ended, before the feed ends. Thus a
    /// round trip that is still in flight here is a defect, and the relay
    /// writes a warning for it. The answer that goes to Router is `cancel`,
    /// so a suspended tool resumes. An answer that arrives after this call
    /// finds no waiter and is dropped. The outstanding URL-mode ids are
    /// cleared with the other per-round-trip state.
    func drainOpenRoundTrips() {
        for task in answerTasks.values {
            task.cancel()
        }
        answerTasks = [:]
        outstandingURLElicitationIds = []
        earlyEnds = [:]
        let waiting = pendingAnswers
        pendingAnswers = [:]
        for (elicitationId, continuation) in waiting {
            ACPAgentTelemetry.logger(.elicitationRelay).warning(
                "A client request was still in flight at the end of the feed. The relay delivers cancel.",
                metadata: elicitationMetadata(elicitationId))
            continuation.resume(returning: .answered(.cancel))
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
    /// - Returns: The answer that went to Router, or the response of the end
    ///   that Router sent.
    private func deliverRoundTrip(
        _ wireRequest: CreateElicitationRequest,
        elicitationId: String,
        mode: ElicitationMode,
        on session: any RoutedSession
    ) async -> ElicitationResponse {
        let answer: ElicitationResponse
        switch await clientAnswer(to: wireRequest, elicitationId: elicitationId, mode: mode) {
        case .answered(let response):
            answer = response
        case .ended(let end):
            return end.response
        }
        let delivery = await session.respond(elicitationId: elicitationId, response: answer)
        switch delivery {
        case .delivered:
            break
        case .acceptedAwaitingCompletion:
            await completeURLFlow(elicitationId: elicitationId, on: session)
        case .noPendingElicitation:
            ACPAgentTelemetry.logger(.elicitationRelay).warning(
                "Router has no pending elicitation for the answer. The relay dropped the answer.",
                metadata: elicitationMetadata(elicitationId))
        @unknown default:
            ACPAgentTelemetry.logger(.elicitationRelay).debug(
                "Router gave an unknown delivery result for an elicitation answer.",
                metadata: elicitationMetadata(elicitationId))
        }
        return answer
    }

    /// Sends the create and suspends until the client answers, ``end(_:)``
    /// ends the question, or ``drainOpenRoundTrips()`` resolves the wait with
    /// `cancel`. A question that Router ended before this call sends no
    /// create.
    ///
    /// The wire request runs on its own task, so the relay can stop it: a
    /// cancel of that task makes the connection send `$/cancel_request`.
    /// The task is stored and cancelled at ``end(_:)`` and
    /// ``drainOpenRoundTrips()``, and a late answer finds no waiter and is
    /// dropped.
    ///
    /// - Parameters:
    ///   - wireRequest: The mapped `elicitation/create` request.
    ///   - elicitationId: The pending elicitation's id.
    ///   - mode: The mode of the request.
    /// - Returns: The decoded answer, `cancel`, or the end from Router.
    private func clientAnswer(
        to wireRequest: CreateElicitationRequest, elicitationId: String, mode: ElicitationMode
    ) async -> ClientAnswer {
        await withCheckedContinuation { continuation in
            if let end = earlyEnds.removeValue(forKey: elicitationId) {
                ACPAgentTelemetry.logger(.elicitationRelay).notice(
                    "Router ended a question before its client request. The relay sends no request.",
                    metadata: endMetadata(end))
                continuation.resume(returning: .ended(end))
                return
            }
            pendingAnswers[elicitationId] = continuation
            answerTasks[elicitationId] = Task {
                let raw: CreateElicitationResponse?
                do {
                    guard let connection = self.connection else {
                        throw CancellationError()
                    }
                    raw = try await connection.createElicitation(wireRequest)
                } catch {
                    ACPAgentTelemetry.logger(.elicitationRelay).warning(
                        "The elicitation/create request failed. The relay delivers cancel.",
                        metadata: self.elicitationMetadata(elicitationId, error: error))
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
            ACPAgentTelemetry.logger(.elicitationRelay).debug(
                "An answer arrived after its wait ended. The relay dropped the answer.",
                metadata: elicitationMetadata(elicitationId))
            return
        }
        continuation.resume(returning: .answered(answer))
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
            guard let connection else {
                throw CancellationError()
            }
            try await connection.elicitationComplete(
                CompleteElicitationNotification(
                    elicitationId: ElicitationId(rawValue: elicitationId)))
        } catch {
            ACPAgentTelemetry.logger(.elicitationRelay).warning(
                "The elicitation/complete notification failed.",
                metadata: elicitationMetadata(elicitationId, error: error))
        }
        await session.complete(elicitationId: elicitationId)
    }

    // MARK: - The log metadata

    /// The metadata of a record about one elicitation: the session id and
    /// the elicitation id.
    ///
    /// - Parameter elicitationId: The id of the elicitation.
    /// - Returns: The ``ACPAgentTelemetry/LogMetadataKey/sessionId`` and
    ///   ``ACPAgentTelemetry/LogMetadataKey/elicitationId`` values.
    private func elicitationMetadata(_ elicitationId: String) -> Logger.Metadata {
        var metadata = ACPAgentTelemetry.sessionMetadata(sessionId)
        metadata[ACPAgentTelemetry.LogMetadataKey.elicitationId] = "\(elicitationId)"
        return metadata
    }

    /// The metadata of the end of one question: the session id, the
    /// elicitation id, the action of the response and its reason.
    ///
    /// - Parameter end: The end that Router sent.
    /// - Returns: The ``elicitationMetadata(_:)`` values, the
    ///   ``ACPAgentTelemetry/LogMetadataKey/elicitationOutcome`` value and,
    ///   when the response has one, the
    ///   ``ACPAgentTelemetry/LogMetadataKey/elicitationEndReason`` value.
    private func endMetadata(_ end: ElicitationEnd) -> Logger.Metadata {
        var metadata = elicitationMetadata(end.elicitationId.ulidString)
        metadata[ACPAgentTelemetry.LogMetadataKey.elicitationOutcome] = "\(end.response.action.rawValue)"
        if let reason = end.response.reason {
            metadata[ACPAgentTelemetry.LogMetadataKey.elicitationEndReason] = "\(reason)"
        }
        return metadata
    }

    /// The metadata of an error in one elicitation: the session id, the
    /// elicitation id and the type name of the error, never its message.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the elicitation.
    ///   - error: The error.
    /// - Returns: The ``ACPAgentTelemetry/errorMetadata(_:sessionId:)``
    ///   values and the ``ACPAgentTelemetry/LogMetadataKey/elicitationId``
    ///   value.
    private func elicitationMetadata(_ elicitationId: String, error: any Error) -> Logger.Metadata {
        elicitationMetadata(elicitationId).merging(
            ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId)
        ) { current, _ in current }
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

    /// Why the relay declines an elicitation. The raw value is the reason
    /// of the decline that goes to Router, and it goes into the log record
    /// of the decline.
    enum DeclineReason: String {
        /// The client does not advertise the capability of the mode.
        case unsupportedMode

        /// The request does not carry the payload of its mode.
        case missingPayload

        /// The URL-mode elicitation id is already outstanding on this
        /// connection.
        case duplicateURLElicitationId
    }

    /// Answers Router with a `decline` that carries `reason`
    /// (``declineResponse(for:)``), and writes the reason to the log. No
    /// `elicitation/create` goes out on this path.
    ///
    /// - Parameters:
    ///   - elicitationId: The pending elicitation's id.
    ///   - mode: The mode of the request, for the log.
    ///   - session: The Router session the decline goes to.
    ///   - reason: Why the relay declined, for the log.
    private func decline(
        elicitationId: String, mode: ElicitationMode, on session: any RoutedSession,
        reason: DeclineReason
    ) async {
        var metadata = elicitationMetadata(elicitationId)
        metadata[ACPAgentTelemetry.LogMetadataKey.elicitationMode] = "\(mode.rawValue)"
        metadata[ACPAgentTelemetry.LogMetadataKey.elicitationDeclineReason] = "\(reason.rawValue)"
        ACPAgentTelemetry.logger(.elicitationRelay).notice(
            "The relay declined an elicitation.", metadata: metadata)
        await session.respond(elicitationId: elicitationId, response: Self.declineResponse(for: reason))
    }

    /// The response of a decline of the relay: `decline` with the raw value
    /// of `reason` as its reason.
    ///
    /// - Parameter reason: Why the relay declined.
    /// - Returns: The response that goes to Router.
    static func declineResponse(for reason: DeclineReason) -> ElicitationResponse {
        .decline(reason: reason.rawValue)
    }

    // MARK: - The URL-mode uniqueness duty

    /// Registers a URL-mode flow, or refuses a duplicate id: the
    /// `elicitationId` stays unique among the outstanding URL
    /// elicitations on the connection, as the ACP specification requires.
    /// A form-mode request
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
    /// the run's tool call (the run's `completionToken` is its
    /// `toolCallId`).
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
    /// data out of band, never over ACP (a security duty of the ACP
    /// specification).
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
            ACPAgentTelemetry.logger(.elicitationRelay).warning(
                "An elicitation answer did not decode. The relay delivers cancel.",
                metadata: [ACPAgentTelemetry.LogMetadataKey.elicitationMode: "\(mode.rawValue)"])
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

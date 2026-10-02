import FoundationModelsRouter

/// The session-scoped half of one prompt (task ^64pav2a): the event stream of
/// the whole Router session, and the wait for the end of the work of the
/// session.
///
/// The stream of a caller answer ends while a background run of that answer
/// is open (Router's `streamEvents(to:maxTokens:)` contract). The result of
/// the run comes back as mail, and the answer that the mail starts is
/// visible only on `streamSessionEvents()`. ``PromptExecution`` reads that
/// stream after the caller stream, until ``awaitIdle`` returns, so the
/// prompt does not end before the session has no more work.
struct SessionFollowUp: Sendable {
    /// Every event of the session, from a subscription that the prompt took
    /// before its caller stream started. It also carries each event of the
    /// caller answer.
    let events: AsyncStream<SessionEvent>

    /// Waits until the session has no more work: `true` when the session is
    /// idle, and `false` when the wait was cancelled or the session closed
    /// first (Router's `RoutedSession.awaitIdle()` contract).
    let awaitIdle: @Sendable () async -> Bool

    /// Subscribes to the events of `session`. Call it before the caller
    /// stream starts, so the subscription holds each event of the prompt.
    ///
    /// - Parameter session: The Router session of the prompt.
    /// - Returns: The follow-up over the session.
    static func subscribing(to session: any RoutedSession) async -> SessionFollowUp {
        SessionFollowUp(events: await session.streamSessionEvents()) {
            await session.awaitIdle()
        }
    }
}

/// A copy of the session events of one prompt, which the prompt can close.
///
/// A session-scoped stream never ends while the session lives, so a reader
/// of it cannot learn that it read the last event. When `awaitIdle()`
/// returns `true`, each event of the work of the session is already in
/// the stream, and no new event comes. ``close()`` cancels the reader task
/// at that moment. A cancelled `AsyncStream` iteration still gives each
/// event that the stream holds, and then ends. So the copy gives each
/// event of the work, and then it ends.
///
/// The cancel also ends the subscription, so the session drops it. Each
/// prompt takes one subscription, and the close of the copy releases it,
/// also when the prompt reads no session event.
struct SessionEventBuffer: Sendable {
    /// The copy of the events, in the order of the session.
    let events: AsyncStream<SessionEvent>

    /// The task that reads the session stream into ``events``.
    private let reader: Task<Void, Never>

    /// Starts the copy of `source`.
    ///
    /// - Parameter source: The session-scoped stream of the prompt.
    /// - Returns: The copy.
    static func reading(_ source: AsyncStream<SessionEvent>) -> SessionEventBuffer {
        let (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        let reader = Task {
            for await event in source {
                continuation.yield(event)
            }
            continuation.finish()
        }
        return SessionEventBuffer(events: events, reader: reader)
    }

    /// Ends the copy after the events that the session stream holds now.
    /// Safe to call more than one time.
    func close() {
        reader.cancel()
    }
}

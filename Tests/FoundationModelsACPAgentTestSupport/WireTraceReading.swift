import FoundationModelsACP

/// One event of a trace with the wire sequence number of the frame that carried it, so the
/// events of two readers of one connection can go in one trace in wire order
/// (``WireTraceEvent/merged(_:)``).
public struct SequencedTraceEvent: Sendable {
  /// The sequence number of the event that comes before each frame of the connection: an event
  /// that the client recorded itself, for example the resume request.
  public static let beforeEachFrame: UInt64 = 0

  /// The wire sequence number of the frame that carried the event.
  public let sequence: UInt64

  /// The event.
  public let event: WireTraceEvent

  /// Makes a sequenced event.
  ///
  /// - Parameters:
  ///   - sequence: The wire sequence number of the frame that carried the event.
  ///   - event: The event.
  public init(sequence: UInt64, event: WireTraceEvent) {
    self.sequence = sequence
    self.event = event
  }
}

extension WireTraceEvent {
  /// The events of several readers of one connection as one trace, in wire order. Two events
  /// with the same sequence number keep the order that they have in `events`.
  ///
  /// - Parameter events: The events, each with its wire sequence number.
  /// - Returns: The trace.
  public static func merged(_ events: [SequencedTraceEvent]) -> [WireTraceEvent] {
    events.enumerated()
      .sorted { ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset) }
      .map(\.element.event)
  }
}

extension SessionEventSubscription {
  /// Reads the wire of a `session/resume` as a trace for the validator: the events of all
  /// sessions, in wire order, up to the response of the resume. The one place that turns the
  /// events of a subscription into trace events. An event that makes no trace event is not part
  /// of the trace.
  ///
  /// - Parameters:
  ///   - first: The events that came before the subscription, for example the resume request.
  ///   - settledBy: Tells the last event to read after the response. The read ends after the
  ///     first event, from the response on, that it accepts. With `nil` the read ends at the
  ///     response.
  /// - Returns: The trace. The read also ends when the stream finishes or the task is cancelled.
  public func readResumeTrace(
    startingWith first: [WireTraceEvent] = [],
    settledBy: (@Sendable (WireTraceEvent) -> Bool)? = nil
  ) async -> [WireTraceEvent] {
    await readSequencedResumeTrace(startingWith: first, settledBy: settledBy).map(\.event)
  }

  /// Reads the wire of a `session/resume` like ``readResumeTrace(startingWith:settledBy:)``, and
  /// keeps the wire sequence number of each event. Each event of `first` gets
  /// ``SequencedTraceEvent/beforeEachFrame``.
  ///
  /// - Parameters:
  ///   - first: The events that came before the subscription, for example the resume request.
  ///   - settledBy: Tells the last event to read after the response, as in
  ///     ``readResumeTrace(startingWith:settledBy:)``.
  /// - Returns: The trace, with the sequence numbers. The read also ends when the stream
  ///   finishes or the task is cancelled.
  public func readSequencedResumeTrace(
    startingWith first: [WireTraceEvent] = [],
    settledBy: (@Sendable (WireTraceEvent) -> Bool)? = nil
  ) async -> [SequencedTraceEvent] {
    var seen = first.map {
      SequencedTraceEvent(sequence: SequencedTraceEvent.beforeEachFrame, event: $0)
    }
    var responded = false
    for await sequenced in events {
      guard let event = WireTraceEvent(sequenced) else {
        continue
      }
      seen.append(SequencedTraceEvent(sequence: sequenced.sequence, event: event))
      if event.isResumeResponse {
        responded = true
      }
      if responded, settledBy?(event) ?? true {
        break
      }
    }
    return seen
  }
}

extension SessionEventSubscription {
  /// Reads the wire of a `session/resume` like ``readResumeTrace(startingWith:settledBy:)`` while
  /// `request` runs, and ends the read at `timeout` when the events never settle it.
  ///
  /// - Parameters:
  ///   - first: The events that came before the subscription, for example the resume request.
  ///   - settledBy: Tells the last event to read after the response, as in
  ///     ``readResumeTrace(startingWith:settledBy:)``.
  ///   - timeout: The longest time that the read waits.
  ///   - request: The request that makes the wire, for example the resume call.
  /// - Returns: The trace. The read also ends when the stream finishes.
  /// - Throws: The error of `request`. The read is cancelled then.
  public func readResumeTrace(
    startingWith first: [WireTraceEvent] = [],
    settledBy: (@Sendable (WireTraceEvent) -> Bool)? = nil,
    timeout: Duration,
    whileRunning request: () async throws -> Void
  ) async throws -> [WireTraceEvent] {
    try await readSequencedResumeTrace(
      startingWith: first, settledBy: settledBy, timeout: timeout, whileRunning: request
    ).map(\.event)
  }

  /// Reads the wire of a `session/resume` like
  /// ``readSequencedResumeTrace(startingWith:settledBy:)`` while `request` runs, and ends the
  /// read at `timeout` when the events never settle it. The one place that bounds the read of a
  /// resume trace with a clock.
  ///
  /// - Parameters:
  ///   - first: The events that came before the subscription, for example the resume request.
  ///   - settledBy: Tells the last event to read after the response, as in
  ///     ``readResumeTrace(startingWith:settledBy:)``.
  ///   - timeout: The longest time that the read waits.
  ///   - request: The request that makes the wire, for example the resume call.
  /// - Returns: The trace, with the sequence numbers. The read also ends when the stream
  ///   finishes.
  /// - Throws: The error of `request`. The read is cancelled then.
  public func readSequencedResumeTrace(
    startingWith first: [WireTraceEvent] = [],
    settledBy: (@Sendable (WireTraceEvent) -> Bool)? = nil,
    timeout: Duration,
    whileRunning request: () async throws -> Void
  ) async throws -> [SequencedTraceEvent] {
    let reader = Task { await readSequencedResumeTrace(startingWith: first, settledBy: settledBy) }
    let limit = Task {
      do {
        try await Task.sleep(for: timeout)
        reader.cancel()
      } catch {
        // The sleep throws only when the caller cancelled it: the read ended in time.
        return
      }
    }
    defer { limit.cancel() }
    do {
      try await request()
    } catch {
      reader.cancel()
      throw error
    }
    return await reader.value
  }
}

extension WireTraceEvent {
  /// Whether this event is an `agent_message_chunk` whose text contains `text`, on the stream of
  /// `session`. The one place that reads a text chunk of one session out of a trace in the tests.
  ///
  /// - Parameters:
  ///   - text: The text to look for.
  ///   - session: The session.
  /// - Returns: `true` for a chunk that holds the text on that stream.
  public func isAgentText(containing text: String, on session: SessionId) -> Bool {
    if case .update(let stream, let update) = self {
      return stream == session && update.agentMessageText.contains(text)
    }
    return false
  }
}

extension SessionUpdate {
  /// The announcement that this update holds, or `nil` for any other update. The one place that
  /// reads a `subagent_update` out of a session update in the tests.
  public var announcement: SubagentUpdate? {
    if case .subagentUpdate(let announced) = self {
      return announced
    }
    return nil
  }

  /// The text of an `agent_message_chunk`, or an empty text for any other update.
  public var agentMessageText: String {
    if case .agentMessageChunk(let chunk) = self, case .text(let content) = chunk.content {
      return content.text
    }
    return ""
  }

  /// Whether this update is an announcement of `child`.
  ///
  /// - Parameter child: The child.
  /// - Returns: `true` for a `subagent_update` that names `child`.
  public func announces(_ child: SessionId) -> Bool {
    announcement?.sessionId == child
  }
}

extension WireTraceEvent {
  /// Whether this event is the response of the resume request.
  public var isResumeResponse: Bool {
    if case .resumeResponse = self {
      return true
    }
    return false
  }
}

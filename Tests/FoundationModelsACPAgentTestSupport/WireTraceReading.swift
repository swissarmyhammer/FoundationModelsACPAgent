import FoundationModelsACP

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
    var seen = first
    var responded = false
    for await sequenced in events {
      guard let event = WireTraceEvent(sequenced) else {
        continue
      }
      seen.append(event)
      if case .resumeResponse = event {
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
  /// `request` runs, and ends the read at `timeout` when the events never settle it. The one place
  /// that bounds the read of a resume trace with a clock.
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
    let reader = Task { await readResumeTrace(startingWith: first, settledBy: settledBy) }
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

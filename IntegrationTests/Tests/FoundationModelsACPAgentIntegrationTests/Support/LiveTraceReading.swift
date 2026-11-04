import FoundationModelsACP
import FoundationModelsACPAgentTestSupport

extension SessionEventSubscription {
  /// Reads the wire of a live run as a trace for the validator, from the next event on, until the
  /// trace is settled. The read ends at `timeout` when the events never settle it, so a hung
  /// agent makes a failed check and not a hung test.
  ///
  /// - Parameters:
  ///   - seen: The events that an earlier read returned. The result extends them.
  ///   - settled: Tells the end of the read from the trace so far.
  ///   - timeout: The longest time that the read waits.
  /// - Returns: The trace. The read also ends when the stream finishes.
  func readLiveTrace(
    extending seen: [WireTraceEvent] = [],
    until settled: @escaping @Sendable ([WireTraceEvent]) -> Bool,
    timeout: Duration
  ) async -> [WireTraceEvent] {
    let reader = Task { () -> [WireTraceEvent] in
      var trace = seen
      if settled(trace) {
        return trace
      }
      for await sequenced in events {
        guard let event = WireTraceEvent(sequenced) else {
          continue
        }
        trace.append(event)
        if settled(trace) {
          break
        }
      }
      return trace
    }
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
    return await reader.value
  }
}

extension WireTraceEvent {
  /// The session whose stream carries this event, or `nil` for a request or a response.
  var stream: SessionId? {
    if case .update(let stream, _) = self {
      return stream
    }
    return nil
  }

  /// The session update that this event holds, or `nil` for a request or a response.
  var sessionUpdate: SessionUpdate? {
    if case .update(_, let update) = self {
      return update
    }
    return nil
  }

  /// The state of the `state_update` that this event holds, or `nil` for any other event.
  var stateUpdate: StateUpdate? {
    if case .stateUpdate(let state)? = sessionUpdate {
      return state
    }
    return nil
  }

  /// Whether this event is a `tool_call_update` on the stream of `session`.
  ///
  /// - Parameter session: The session.
  /// - Returns: `true` for a tool call update on that stream.
  func isToolCall(on session: SessionId) -> Bool {
    if stream == session, case .toolCallUpdate? = sessionUpdate {
      return true
    }
    return false
  }

  /// Whether this event is the `idle` state of `session`.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - stopReason: The stop reason that the `idle` must carry, or `nil` for any stop reason.
  /// - Returns: `true` for an `idle` `state_update` on the stream of that session.
  func isIdle(of session: SessionId, stopReason: StopReason? = nil) -> Bool {
    guard stream == session, case .idle(let idle)? = stateUpdate else {
      return false
    }
    return stopReason == nil || idle.stopReason == stopReason
  }

  /// Whether this event is the announcement of `child`, with a `subagent_update` on the stream
  /// of `parent`.
  ///
  /// - Parameters:
  ///   - child: The announced session.
  ///   - parent: The session whose stream carries the announcement.
  /// - Returns: `true` for the announcement of that child on that stream.
  func isAnnouncement(of child: SessionId, on parent: SessionId) -> Bool {
    if case .update(let stream, let update) = self {
      return stream == parent && update.announces(child)
    }
    return false
  }
}

extension [WireTraceEvent] {
  /// The child that the first announcement on the stream of `parent` names.
  ///
  /// - Parameter parent: The session whose stream carries the announcement.
  /// - Returns: The announced session, or `nil` when the trace holds no announcement there.
  func firstChild(of parent: SessionId) -> SessionId? {
    for case .update(let stream, let update) in self where stream == parent {
      if let announced = update.announcement {
        return announced.sessionId
      }
    }
    return nil
  }

  /// The id of the first tool call that the stream of `session` shows.
  ///
  /// - Parameter session: The session.
  /// - Returns: The id, or `nil` when the stream shows no tool call.
  func firstToolCallId(on session: SessionId) -> ToolCallId? {
    for case .update(let stream, .toolCallUpdate(let call)) in self where stream == session {
      return call.toolCallId
    }
    return nil
  }

  /// The child of `root` and the child of that child, from the first announcements.
  ///
  /// - Parameter root: The root session.
  /// - Returns: The child and the grandchild, or `nil` when the trace does not name both yet.
  func chain(of root: SessionId) -> (child: SessionId, leaf: SessionId)? {
    guard let child = firstChild(of: root), let leaf = firstChild(of: child) else {
      return nil
    }
    return (child, leaf)
  }
}

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

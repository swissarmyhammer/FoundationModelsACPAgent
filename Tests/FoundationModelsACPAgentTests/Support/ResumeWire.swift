import FoundationModelsACP
import FoundationModelsACPAgentTestSupport

/// The subscription to all sessions of the connection of a ``ScriptedPromptFixture``, for the
/// read of the wire of a `session/resume` of a session that the fixture did not open. The one
/// place that keeps the own session of the fixture out of a resume trace.
///
/// The fixture opens its own session with `session/new`. That session sends its default name
/// after the `session/new` response, and the fixture returns at the response. So the update can
/// come after the read starts. The resume request does not announce that session, so its events
/// are not part of the trace. Each read here leaves them out.
struct ResumeWire: Sendable {
  /// The subscription to all sessions of the connection.
  let subscription: SessionEventSubscription

  /// The own session of the fixture: the session that it opened with `session/new`.
  let ownSession: SessionId

  /// Reads the wire of the resume, as
  /// ``SessionEventSubscription/readResumeTrace(startingWith:leavingOut:settledBy:)`` does, and
  /// leaves out the own session of the fixture.
  ///
  /// - Parameters:
  ///   - first: The events that came before the subscription, for example the resume request.
  ///   - settledBy: Tells the last event to read after the response.
  /// - Returns: The trace.
  func readResumeTrace(
    startingWith first: [WireTraceEvent] = [],
    settledBy: (@Sendable (WireTraceEvent) -> Bool)? = nil
  ) async -> [WireTraceEvent] {
    await subscription.readResumeTrace(
      startingWith: first, leavingOut: [ownSession], settledBy: settledBy)
  }

  /// Reads the wire of the resume while `request` runs, as the `readResumeTrace` of
  /// ``SessionEventSubscription`` with a `timeout` does, and leaves out the own session of the
  /// fixture.
  ///
  /// - Parameters:
  ///   - first: The events that came before the subscription, for example the resume request.
  ///   - settledBy: Tells the last event to read after the response.
  ///   - timeout: The longest time that the read waits.
  ///   - request: The request that makes the wire, for example the resume call.
  /// - Returns: The trace.
  /// - Throws: The error of `request`.
  func readResumeTrace(
    startingWith first: [WireTraceEvent] = [],
    settledBy: (@Sendable (WireTraceEvent) -> Bool)? = nil,
    timeout: Duration,
    whileRunning request: () async throws -> Void
  ) async throws -> [WireTraceEvent] {
    try await subscription.readResumeTrace(
      startingWith: first, leavingOut: [ownSession], settledBy: settledBy, timeout: timeout,
      whileRunning: request)
  }
}

extension ScriptedPromptFixture {
  /// Subscribes to all sessions of the connection of this fixture, for the read of the wire of a
  /// `session/resume` of a session that this fixture did not open. Each read of the subscription
  /// leaves out the own session of this fixture.
  ///
  /// - Returns: The subscription.
  func subscribeToTheResumeWire() -> ResumeWire {
    ResumeWire(subscription: harness.connection.subscribeToAllSessions(), ownSession: sessionId)
  }
}

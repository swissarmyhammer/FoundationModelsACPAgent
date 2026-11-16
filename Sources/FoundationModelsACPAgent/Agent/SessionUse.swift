import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter

/// The record of the last use of a session (ACPA-9, D118, D184).
///
/// When a client opens a session with `session/new` or `session/resume`,
/// the agent tells the session directory that the session was used now
/// (`SessionDirectory.markUsed(_:)`). The Recent list of the `sessions`
/// endpoint reads this time.
///
/// The record is best effort: a failure gives a log warning, and the open
/// of the session continues. The directory keeps the time in the
/// machine-local usage store of the server, not in the recording of the
/// session (D118 (e)).
extension RoutedACPAgent {
  /// The function that records one use of a session: by default
  /// `markUsed(_:)` of ``sessionDirectory``.
  typealias SessionUseRecorder = @Sendable (ULID) async throws -> Void

  /// The default recorder over `directory`.
  ///
  /// - Parameter directory: The session directory of the agent.
  /// - Returns: The recorder.
  static func makeSessionUseRecorder(
    directory: any SessionDirectory
  ) -> SessionUseRecorder {
    { id in _ = try await directory.markUsed(id) }
  }

  /// Replaces the recorder of the use of a session. A test gives a
  /// recorder that keeps each id.
  ///
  /// - Parameter recorder: The new recorder.
  func useSessionUseRecorder(_ recorder: @escaping SessionUseRecorder) {
    sessionUseRecorder = recorder
  }

  /// Records that a client used the session `sessionId` now.
  ///
  /// - Parameter sessionId: The id of the session that a client opened.
  func recordUse(of sessionId: SessionId) async {
    guard let id = ULID(ulidString: sessionId.rawValue) else {
      return
    }
    do {
      try await sessionUseRecorder(id)
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The agent could not record the use of the session. The session is open.",
        metadata: ACPAgentTelemetry.sessionMetadata(sessionId))
    }
  }
}

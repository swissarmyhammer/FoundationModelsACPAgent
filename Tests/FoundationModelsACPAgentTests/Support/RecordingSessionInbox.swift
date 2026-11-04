import FoundationModelsACP
import Synchronization

@testable import FoundationModelsACPAgent

/// A session inbox of a ``SubagentMessageProjector`` that records the updates it gets. A test
/// attaches it to the projector for a session whose projector the test does not run.
final class RecordingSessionInbox: Sendable {
  /// The updates, in the order that the inbox got them.
  private let log = Mutex<[SessionUpdate]>([])

  /// The updates, in the order that the inbox got them.
  var updates: [SessionUpdate] { log.withLock { $0 } }

  /// The `session_message` payloads among the updates, in order.
  var messages: [SessionMessage] { updates.compactMap(\.sessionMessagePayload) }

  /// Records updates in order.
  ///
  /// - Parameter updates: The updates.
  func accept(_ updates: [SessionUpdate]) {
    log.withLock { $0 += updates }
  }

  /// Records one update.
  ///
  /// - Parameter update: The update.
  func accept(_ update: SessionUpdate) {
    log.withLock { $0.append(update) }
  }
}

extension SessionUpdate {
  /// The `session_message` payload of this update, or `nil` for any other update.
  var sessionMessagePayload: SessionMessage? {
    if case .sessionMessage(let message) = self { return message }
    return nil
  }
}

extension SessionUpdate {
  /// The `subagent_update` payload of this update, or `nil` for any other update.
  var subagentUpdatePayload: SubagentUpdate? {
    if case .subagentUpdate(let update) = self { return update }
    return nil
  }
}

extension SessionMessage {
  /// The text of the first content block of the message, or `nil` when the message holds no
  /// text.
  var firstText: String? {
    guard case .value(let blocks) = content, case .text(let block) = blocks.first else {
      return nil
    }
    return block.text
  }
}

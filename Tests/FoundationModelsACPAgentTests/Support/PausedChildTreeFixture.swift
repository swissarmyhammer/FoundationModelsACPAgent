import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

import struct FoundationModelsRouter.MailDeliveryPause

/// A live tree of two sessions whose child has a pause of the mail delivery in force (task
/// ^c4hafqw).
///
/// The prompt of the root starts the child, and the child plays its text and then waits on a
/// hold. Then the fixture records one `_mail_delivery_paused` update in the history of the
/// child, through the record path that each pause of a child takes
/// (``RoutedACPAgent/recordInHistory(_:of:)``).
struct PausedChildTree {
  // MARK: - Constants

  /// The agent that the root starts.
  static let childAgent = "worker"

  /// The marker of the prompt of the root.
  static let rootMarker = "PAUSED-CHILD-TREE-ROOT"

  /// The marker of the prompt of the child.
  static let childMarker = "PAUSED-CHILD-TREE-CHILD"

  /// The text that the child plays before it waits.
  static let childText = "PAUSED-CHILD-TREE-CHILD-TEXT"

  /// The limit of the recorded pause.
  static let pauseLimit = 0

  /// The `_mail_delivery_paused` update that the fixture records for the child.
  static var pause: SessionUpdate {
    MailDeliveryPauseReport.update(for: MailDeliveryPause(limit: pauseLimit, heldMail: []))
  }

  // MARK: - The tree

  /// The first agent and its first connection.
  let fixture: ScriptedPromptFixture

  /// The task of the open prompt of the root.
  let prompt: Task<PromptResponse, any Error>

  /// The hold that keeps the child running. Release it to let the child end.
  let hold: ScriptedHold

  /// The id of the child session.
  let childId: SessionId

  /// The id of the root session.
  var rootId: SessionId { fixture.sessionId }

  /// The resume request of the root, with a replay from the start.
  var replayRequest: ResumeSessionRequest {
    ResumeSessionRequest(
      cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: rootId,
      replayFrom: .start(ReplayFromStart()))
  }

  /// Starts the tree, waits until the client holds an update of the child, and records the
  /// pause of the child.
  ///
  /// - Parameter label: The directory label of the test.
  /// - Returns: The tree.
  /// - Throws: Whatever the fixture or the wait throws.
  static func start(label: String) async throws -> PausedChildTree {
    let hold = ScriptedHold()
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: childMarker, play: [.textDelta(childText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: rootMarker,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childMarker), .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd)
    let root = fixture.sessionId
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootMarker))
    }
    let updates = try await fixture.collector.wait(for: "an update of the child") { updates in
      updates.contains { $0.sessionId != root }
    }
    let child = try #require(updates.first { $0.sessionId != root }?.sessionId)
    await fixture.harness.agent.recordInHistory(pause, of: child)
    return PausedChildTree(fixture: fixture, prompt: prompt, hold: hold, childId: child)
  }

  // MARK: - The hot resume

  /// Resumes the root on a second connection of the same agent, with a replay. Then it releases
  /// the child and waits until the second connection holds an `idle` state of the child: the end
  /// of its turn. A child sends no stop reason in its `idle`.
  /// The live updates of the child go out after the sync of the child, so the wait ends after
  /// each update of the sync.
  ///
  /// - Returns: The updates of the stream of the child on the second connection, in order.
  /// - Throws: Whatever the handshake, the request or the waits throw.
  func resumeOnASecondConnection() async throws -> [SessionUpdate] {
    let second = await AgentClientHarness.makeRecording(agent: fixture.harness.agent)
    _ = try await second.client.initialize(AgentClientHarness.makeInitializeRequest())
    _ = try await second.connection.resumeSession(replayRequest)
    hold.release()
    let child = childId
    let updates = try await #require(second.collector).wait(for: "the child ends its turn") {
      updates in
      updates.contains { $0.sessionId == child && $0.update.isIdle }
    }
    _ = try await prompt.value
    return updates.filter { $0.sessionId == child }.map(\.update)
  }

  /// Lifts the pause of the child, as a delivered mail of the child does
  /// (``RoutedACPAgent/liftMailDeliveryPause(of:)``).
  func liftThePause() async {
    await fixture.harness.agent.liftMailDeliveryPause(of: childId)
  }

  // MARK: - The cold restore

  /// Kills the first agent while the child works, and restores the tree in a second agent over
  /// the same working directory. The history of each session is on disk, as the end of a prompt
  /// writes it. The sessions are suspended, so the runs stay orphans and the child restores as a
  /// live child. The wait ends at the own `state_update` of the child: the sync of the child.
  ///
  /// - Parameter label: The directory label of the second agent.
  /// - Returns: The second agent, and the updates of the stream of the child up to its own
  ///   `state_update`, in order.
  /// - Throws: Whatever the fixture, the request or the wait throws.
  func restoreInASecondAgent(
    label: String
  ) async throws -> (agent: ScriptedPromptFixture, childUpdates: [SessionUpdate]) {
    let agent = fixture.harness.agent
    for sessionId in await agent.sessions.keys {
      await agent.writeHistory(of: sessionId)
    }
    for entry in await agent.sessions.values {
      entry.session.suspend()
    }
    let second = try await ScriptedPromptFixture.make(
      script: [.endPass], label: label, workingDirectory: fixture.cwd)
    _ = try await second.harness.connection.resumeSession(replayRequest)
    let child = childId
    let updates = try await second.collector.wait(for: "the own state of the child") { updates in
      updates.contains { $0.sessionId == child && $0.update.isStateUpdate }
    }
    return (second, updates.filter { $0.sessionId == child }.map(\.update))
  }
}

extension SessionUpdate {
  /// Whether this update is an `idle` state update.
  fileprivate var isIdle: Bool {
    guard case .stateUpdate(.idle) = self else {
      return false
    }
    return true
  }
}

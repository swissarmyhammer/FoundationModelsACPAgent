import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// The messages between a caller and a child reach the client as `session_message` updates, each
/// in the stream of the right session. The child runs on a scripted model: it sends one message to
/// its caller with `send caller`, and then it finishes.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct SubagentMessageWireTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "SubagentMessageWireTests"

  /// The agent that the root session starts.
  private static let childAgent = "messenger"

  /// The marker of the prompt of the root session.
  private static let rootMarker = "ROOT-STARTS-A-MESSENGER"

  /// The marker of the prompt of the child.
  private static let childMarker = "CHILD-MESSAGES-ITS-CALLER-NOW"

  /// The text of the message that the child sends to its caller.
  private static let message = "CHILD-HALF-WAY-REPORT"

  /// The final text of the child.
  private static let finalText = "CHILD-FINAL-RESULT"

  /// The marker of the prompt of the child in the test of `send agent`.
  private static let waitingChildMarker = "CHILD-WAITS-FOR-A-MESSAGE-NOW"

  /// The text of the message that the root session sends to the child with `send agent`.
  private static let rootMessage = "ROOT-ASKS-FOR-THE-SECOND-FILE"

  /// The wire updates of one run, in wire order, after the child ended.
  private struct Run {
    /// The id of the root session.
    let root: SessionId

    /// The id of the child session.
    let child: SessionId

    /// The notifications, in wire order.
    let notifications: [UpdateSessionNotification]

    /// The `session_message` updates of one session, in wire order.
    func messages(of session: SessionId) -> [FoundationModelsACP.SessionMessage] {
      notifications.filter { $0.sessionId == session }.compactMap(\.update.sessionMessagePayload)
    }
  }

  /// Starts the root session with a child that sends one message and finishes, and waits until the
  /// child ended.
  ///
  /// - Returns: The run.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func runMessengerChild() async throws -> Run {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let sendCaller = ScriptedPassStep.toolCall(
      name: AgentsToolTests.agentsToolName,
      argumentsJSON: #"{"op":"send caller","message":"\#(message)"}"#)
    let script: [ScriptedPassStep] = [
      .onPrompt(containing: childMarker, play: [sendCaller, .textDelta(finalText), .endPass]),
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
    let ended = try await fixture.collector.wait(for: "the child ends") { updates in
      updates.contains { notification in
        guard notification.sessionId != root,
          case .stateUpdate(.idle(let idle)) = notification.update
        else { return false }
        return idle.stopReason != nil
      }
    }
    _ = try await prompt.value
    let child = try #require(ended.first { $0.sessionId != root }?.sessionId)
    await fixture.close()
    return Run(root: root, child: child, notifications: await fixture.collector.updates)
  }

  @Test("the message of a child to its caller is an outgoing view in the child stream")
  func theMessageIsAnOutgoingViewInTheChildStream() async throws {
    let run = try await Self.runMessengerChild()

    let outgoing = run.messages(of: run.child).first { $0.firstText == Self.message }

    #expect(outgoing?.senderSessionId == .value(run.child))
    #expect(outgoing?.recipientSessionId == .value(run.root))
  }

  @Test("the message of a child to its caller is an incoming view in the caller stream")
  func theMessageIsAnIncomingViewInTheCallerStream() async throws {
    let run = try await Self.runMessengerChild()

    let incoming = try #require(run.messages(of: run.root).first { $0.firstText == Self.message })
    let outgoing = try #require(run.messages(of: run.child).first { $0.firstText == Self.message })

    #expect(incoming.senderSessionId == .value(run.child))
    #expect(incoming.senderMessageId == .value(outgoing.messageId))
  }

  @Test("the outgoing view names the incoming view after the caller received the message")
  func theOutgoingViewNamesTheIncomingView() async throws {
    let run = try await Self.runMessengerChild()

    let incoming = try #require(run.messages(of: run.root).first { $0.firstText == Self.message })
    let outgoing = try #require(run.messages(of: run.child).first { $0.firstText == Self.message })
    let link = run.messages(of: run.child).first {
      $0.messageId == outgoing.messageId && $0.recipientMessageId != .unchanged
    }

    #expect(link?.recipientMessageId == .value(incoming.messageId))
  }

  @Test("the final message of a child is an incoming view in the caller stream")
  func theFinalMessageIsAnIncomingViewInTheCallerStream() async throws {
    let run = try await Self.runMessengerChild()

    let final = run.messages(of: run.root).first { $0.firstText?.contains(Self.finalText) == true }

    #expect(final?.senderSessionId == .value(run.child))
  }

  @Test("the final message of a child is an outgoing view in the child stream")
  func theFinalMessageIsAnOutgoingViewInTheChildStream() async throws {
    let run = try await Self.runMessengerChild()

    let final = try #require(run.messages(of: run.child).first { $0.firstText == Self.finalText })
    let incoming = try #require(
      run.messages(of: run.root).first { $0.firstText?.contains(Self.finalText) == true })

    #expect(final.recipientMessageId == .value(incoming.messageId))
  }

  @Test("the incoming view of the final message comes before the last update of the agents call")
  func theFinalViewComesBeforeTheFinalStatus() async throws {
    let run = try await Self.runMessengerChild()
    let rootUpdates = run.notifications.filter { $0.sessionId == run.root }

    let view = rootUpdates.firstIndex {
      $0.update.sessionMessagePayload?.firstText?.contains(Self.finalText) == true
    }
    let finalStatus = rootUpdates.lastIndex {
      guard case .toolCallUpdate(let call) = $0.update else { return false }
      return call.status == .value(.completed)
    }

    #expect(try #require(view) < #require(finalStatus))
  }

  @Test("every view of the child comes before its last state")
  func everyViewComesBeforeTheEndOfTheChild() async throws {
    let run = try await Self.runMessengerChild()
    let childUpdates = run.notifications.filter { $0.sessionId == run.child }

    let lastView = childUpdates.lastIndex { $0.update.sessionMessagePayload != nil }
    let ended = childUpdates.lastIndex {
      if case .stateUpdate(.idle(let idle)) = $0.update { return idle.stopReason != nil }
      return false
    }

    #expect(try #require(lastView) < #require(ended))
  }

  // MARK: - send agent

  /// The wire updates of one run of `send agent`.
  ///
  /// The root session starts a child that waits at a gate. The child id is known only when the
  /// child is announced, so the script of the root session reads the arguments of its
  /// `send agent` call from a file that the test writes after the announcement. The test opens the
  /// gate of the child when the root session sent its message, so the child gets the mail in its
  /// next turn.
  ///
  /// - Returns: The run, after the child took the message.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func runSendAgent() async throws -> Run {
    let cwd = makeResolvedDirectory(label: "\(label)-send-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let folder = makeResolvedDirectory(label: "\(label)-send-files")
    let argumentsPath = folder.appendingPathComponent("send-agent.json").path
    let gatePath = folder.appendingPathComponent("child-gate").path
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: waitingChildMarker, play: [.gate(path: gatePath), .textDelta(finalText), .endPass]),
      .onPrompt(
        containing: rootMarker,
        play: [
          AgentsToolTests.startAgentCall(agent: childAgent, prompt: waitingChildMarker),
          .toolCallFromFile(name: AgentsToolTests.agentsToolName, path: argumentsPath), .endPass,
        ]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd)
    let root = fixture.sessionId
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootMarker))
    }
    let announced = try await fixture.collector.wait(for: "the child is announced") { updates in
      updates.contains { $0.update.subagentUpdatePayload != nil }
    }
    let child = try #require(announced.compactMap { $0.update.subagentUpdatePayload }.first?.sessionId)
    try #"{"op":"send agent","id":"\#(child.rawValue)","message":"\#(rootMessage)"}"#.write(
      toFile: argumentsPath, atomically: true, encoding: .utf8)
    _ = try await fixture.collector.wait(for: "the root session sent its message") { updates in
      updates.contains {
        $0.sessionId == root && $0.update.sessionMessagePayload?.firstText == rootMessage
      }
    }
    try "open".write(toFile: gatePath, atomically: true, encoding: .utf8)
    _ = try await fixture.collector.wait(for: "the child took the message") { updates in
      updates.contains {
        $0.sessionId == child && $0.update.sessionMessagePayload?.firstText == rootMessage
      }
    }
    _ = try await prompt.value
    await fixture.close()
    return Run(root: root, child: child, notifications: await fixture.collector.updates)
  }

  @Test("send agent is an outgoing view in the caller stream")
  func sendAgentIsAnOutgoingViewInTheCallerStream() async throws {
    let run = try await Self.runSendAgent()

    let outgoing = run.messages(of: run.root).first { $0.firstText == Self.rootMessage }

    #expect(outgoing?.senderSessionId == .value(run.root))
    #expect(outgoing?.recipientSessionId == .value(run.child))
  }

  @Test("send agent is an incoming view in the child stream")
  func sendAgentIsAnIncomingViewInTheChildStream() async throws {
    let run = try await Self.runSendAgent()

    let incoming = try #require(
      run.messages(of: run.child).first { $0.firstText == Self.rootMessage })
    let outgoing = try #require(
      run.messages(of: run.root).first { $0.firstText == Self.rootMessage })

    #expect(incoming.senderSessionId == .value(run.root))
    #expect(incoming.senderMessageId == .value(outgoing.messageId))
  }

  @Test("send agent links the outgoing view to the incoming view after the child took the mail")
  func sendAgentLinksTheOutgoingView() async throws {
    let run = try await Self.runSendAgent()

    let incoming = try #require(run.messages(of: run.child).first { $0.firstText == Self.rootMessage })
    let outgoing = try #require(run.messages(of: run.root).first { $0.firstText == Self.rootMessage })
    let link = run.messages(of: run.root).first {
      $0.messageId == outgoing.messageId && $0.recipientMessageId != .unchanged
    }

    #expect(link?.recipientMessageId == .value(incoming.messageId))
  }

  @Test("send agent sends the outgoing view one time")
  func sendAgentSendsTheOutgoingViewOneTime() async throws {
    let run = try await Self.runSendAgent()

    let outgoing = run.messages(of: run.root).filter { $0.firstText == Self.rootMessage }

    #expect(outgoing.count == 1)
  }
}

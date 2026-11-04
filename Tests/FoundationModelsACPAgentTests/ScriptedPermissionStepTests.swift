import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent

/// The `permission` step of the scripted stub model: the pass sends
/// `session/request_permission` to the client, waits for the outcome, and
/// goes on after a selected option. A cancelled outcome ends the pass, as a
/// cancel ends the pass of an `elicit` step. The request goes out under the
/// session id of the run.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ScriptedPermissionStepTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ScriptedPermissionStepTests"

  /// The marker of the prompt whose pass asks.
  private static let askMarker = "Ask the permission"

  /// The title of the permission request.
  private static let title = "Run the build?"

  /// The text that the pass plays after the request.
  private static let afterText = "TEXT-AFTER-THE-PERMISSION"

  /// The number of requests that one `permission` step makes at the client.
  private static let requestsOfOneStep = 1

  /// The steps of the asking pass, with the text after the request.
  private static func askingScript() -> [ScriptedPassStep] {
    [
      .onPrompt(
        containing: askMarker,
        play: [.permission(title: title), .textDelta(afterText), .endPass]),
      .endPass,
    ]
  }

  /// How the client ends the request.
  private enum Resolution {
    /// The user selects the option with this id.
    case select(String)

    /// The user cancels the request.
    case cancel
  }

  /// Sends the asking prompt, waits until the client holds the request,
  /// and ends it as `resolution` says.
  ///
  /// - Parameter resolution: How the client ends the request.
  /// - Returns: The fixture, which the caller closes, and the notifications
  ///   of the session to the idle of the prompt.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func run(resolving resolution: Resolution) async throws
    -> (fixture: ScriptedPromptFixture, updates: [UpdateSessionNotification])
  {
    let fixture = try await ScriptedPromptFixture.make(script: askingScript(), label: label)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: askMarker))
    let session = fixture.session
    let pending = try await PermissionWait.firstPendingPermission(in: session)
    switch resolution {
    case .select(let optionId):
      await session.selectPermission(pending.id, option: PermissionOptionId(rawValue: optionId))
    case .cancel:
      await session.cancelPermission(pending.id)
    }
    let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
    return (fixture, updates)
  }

  // MARK: - The request

  /// One step makes one request at the client, and it names the session of
  /// the run.
  @Test func theRequestGoesOutOnceUnderTheSessionOfTheRun() async throws {
    let run = try await Self.run(resolving: .select(ScriptedPermission.allowOptionId))
    let requests = await run.fixture.harness.elicitations?.permissions ?? []

    #expect(requests.map(\.sessionId) == [run.fixture.sessionId])
    await run.fixture.close()
  }

  /// The request carries the title of the step.
  @Test func theRequestCarriesTheTitleOfTheStep() async throws {
    let run = try await Self.run(resolving: .select(ScriptedPermission.allowOptionId))
    let requests = await run.fixture.harness.elicitations?.permissions ?? []

    #expect(requests.map(\.title) == [Self.title])
    await run.fixture.close()
  }

  /// The request offers allow once and reject once.
  @Test func theRequestOffersAllowOnceAndRejectOnce() async throws {
    let run = try await Self.run(resolving: .select(ScriptedPermission.allowOptionId))
    let requests = await run.fixture.harness.elicitations?.permissions ?? []

    #expect(requests.first?.options.map(\.kind) == [.allowOnce, .rejectOnce])
    await run.fixture.close()
  }

  // MARK: - The outcome

  /// The pass goes on with its next step after a selected option.
  @Test func thePassGoesOnAfterASelectedOption() async throws {
    let run = try await Self.run(resolving: .select(ScriptedPermission.allowOptionId))

    #expect(ScriptedPromptFixture.agentText(in: run.updates) == Self.afterText)
    await run.fixture.close()
  }

  /// A selected reject option is an answer too: the pass goes on, and the
  /// script decides what the rejection means.
  @Test func thePassGoesOnAfterARejectOption() async throws {
    let run = try await Self.run(resolving: .select(ScriptedPermission.rejectOptionId))

    #expect(ScriptedPromptFixture.agentText(in: run.updates) == Self.afterText)
    await run.fixture.close()
  }

  /// A cancelled outcome ends the pass with the text of a cancel, and the
  /// steps after the request do not play.
  @Test func aCancelledOutcomeEndsThePass() async throws {
    let run = try await Self.run(resolving: .cancel)

    #expect(ScriptedPromptFixture.agentText(in: run.updates) == ScriptedElicitation.cancelledText)
    await run.fixture.close()
  }

  /// A session whose client cannot answer a form has no `elicit` in its
  /// sandbox. The step then ends the pass with a clear text, and no request
  /// goes to the client.
  @Test func aSessionWithNoUserEndsThePassWithAClearText() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: Self.askingScript(), label: Self.label, capabilities: ClientCapabilities())
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.askMarker))
    let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)

    #expect(ScriptedPromptFixture.agentText(in: updates) == ScriptedElicitation.unavailableText)
    await fixture.close()
  }
}

/// The `permission` step in a child run: the request goes to the client one
/// time, under the session id of the child and never under the root. A cancel
/// of the child ends the request that waits.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ChildPermissionTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ChildPermissionTests"

  /// The agent that the root session starts.
  private static let childAgent = "asker"

  /// The marker of the prompt of the root session.
  private static let rootMarker = "ROOT-STARTS-A-CHILD-THAT-ASKS-PERMISSION"

  /// The marker of the prompt of the child.
  private static let childMarker = "CHILD-ASKS-PERMISSION-NOW"

  /// The title of the permission request.
  private static let title = "Delete the folder?"

  /// The text that the child plays after the request.
  private static let afterText = "CHILD-TEXT-AFTER-THE-PERMISSION"

  /// The number of requests that one `permission` step of a child makes at
  /// the client.
  private static let requestsOfOneStep = 1

  /// One run of the root session with a child that asks permission.
  private struct AskingRun {
    /// The fixture. The caller closes it.
    let fixture: ScriptedPromptFixture

    /// The client model of the child session.
    let child: SessionModel

    /// The id of the child session.
    var childId: SessionId { child.sessionId }

    /// The id of the root session.
    var rootId: SessionId { fixture.sessionId }
  }

  /// Starts the root session with a child that asks permission, and waits
  /// until the client holds the request at the model of the child.
  ///
  /// - Returns: The run.
  /// - Throws: Whatever the fixture or a wait throws.
  private static func startAskingRun() async throws -> AskingRun {
    let cwd = makeResolvedDirectory(label: "\(label)-repo")
    try AgentsToolTests.writeAgent(named: childAgent, in: cwd)
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: childMarker,
        play: [.permission(title: title), .textDelta(afterText), .endPass]),
      .onPrompt(
        containing: rootMarker,
        play: [AgentsToolTests.startAgentCall(agent: childAgent, prompt: childMarker), .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: label, workingDirectory: cwd)
    let root = fixture.sessionId
    _ = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: rootMarker))
    }
    let rootModel = fixture.session
    try await ObservedValue.wait(for: "the child holds the request") {
      rootModel.children.first?.pendingPermissions.isEmpty == false
    }
    let child = try #require(await rootModel.children.first)
    return AskingRun(fixture: fixture, child: child)
  }

  /// Waits for the end of the turn of the child, then gives the
  /// notifications of the wire.
  ///
  /// - Parameter run: The run.
  /// - Returns: The notifications, in wire order.
  /// - Throws: Whatever the wait throws.
  private static func waitForTheEndOfTheChild(_ run: AskingRun) async throws
    -> [UpdateSessionNotification]
  {
    let root = run.rootId
    return try await run.fixture.collector.wait(for: "the child ends") { updates in
      endStopReason(in: updates.filter { $0.sessionId != root }) != nil
    }
  }

  /// The stop reason of the first `idle` that has one.
  ///
  /// - Parameter updates: The notifications.
  /// - Returns: The stop reason, or `nil`.
  private static func endStopReason(in updates: [UpdateSessionNotification]) -> StopReason? {
    updates.lazy.compactMap { notification -> StopReason? in
      if case .stateUpdate(.idle(let idle)) = notification.update { return idle.stopReason }
      return nil
    }.first
  }

  /// The request of a child arrives with the session id of the child, one
  /// time, and no request names the root.
  @Test func theRequestOfAChildGoesOutOnceUnderTheChildSessionId() async throws {
    let run = try await Self.startAskingRun()
    let recorder = try #require(run.fixture.harness.elicitations)
    let requests = try await recorder.waitForPermissions(count: Self.requestsOfOneStep)
    let pending = try await PermissionWait.firstPendingPermission(in: run.child)
    await run.child.cancelPermission(pending.id)
    _ = try await Self.waitForTheEndOfTheChild(run)

    let all = await recorder.permissions

    #expect(requests.first?.sessionId == run.childId)
    #expect(all.map(\.sessionId) == [run.childId])
    await run.fixture.close()
  }

  /// The root session does not hold the request of its child.
  @Test func theRootHoldsNoRequestOfItsChild() async throws {
    let run = try await Self.startAskingRun()
    let rootModel = run.fixture.session
    let rootHeld = await rootModel.pendingPermissions.count
    let pending = try await PermissionWait.firstPendingPermission(in: run.child)
    await run.child.cancelPermission(pending.id)
    _ = try await Self.waitForTheEndOfTheChild(run)

    #expect(rootHeld == 0)
    await run.fixture.close()
  }

  /// The answer of the user reaches the child run. The run goes on and plays
  /// its next text under the child id.
  @Test func theSelectedOptionReachesTheRunThatAsked() async throws {
    let run = try await Self.startAskingRun()
    let pending = try await PermissionWait.firstPendingPermission(in: run.child)
    await run.child.selectPermission(
      pending.id, option: PermissionOptionId(rawValue: ScriptedPermission.allowOptionId))

    let updates = try await Self.waitForTheEndOfTheChild(run)

    let childText = ScriptedPromptFixture.agentText(
      in: updates.filter { $0.sessionId == run.childId })
    #expect(childText.contains(Self.afterText))
    await run.fixture.close()
  }

  /// A cancel of the child while the request waits ends the request: the
  /// client holds no request of the child any more.
  @Test func aCancelOfTheChildEndsItsPendingRequest() async throws {
    let run = try await Self.startAskingRun()

    try await run.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: run.childId))
    try await PermissionWait.waitUntilNoPendingPermission(in: run.child)

    #expect(await run.child.pendingPermissions.isEmpty)
    await run.fixture.close()
  }

  /// A cancel of the child ends the pass of the child as cancelled.
  @Test func aCancelOfTheChildEndsItsPassAsCancelled() async throws {
    let run = try await Self.startAskingRun()

    try await run.fixture.harness.connection.sessionCancel(
      CancelSessionNotification(sessionId: run.childId))
    let updates = try await Self.waitForTheEndOfTheChild(run)

    let childUpdates = updates.filter { $0.sessionId == run.childId }
    #expect(Self.endStopReason(in: childUpdates) == .cancelled)
    await run.fixture.close()
  }
}

/// The wait for the permission requests that a session sent to the client
/// and that the client did not answer yet.
enum PermissionWait {
  /// Waits until `session` holds a pending permission request, and gives the
  /// first one.
  ///
  /// - Parameter session: The session model that receives the requests.
  /// - Returns: The first pending request of the session.
  /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled first.
  static func firstPendingPermission(in session: SessionModel) async throws
    -> PendingPermissionRequest
  {
    try await ObservedValue.wait(for: "a permission request reaches the client") {
      !session.pendingPermissions.isEmpty
    }
    return try #require(await session.pendingPermissions.first)
  }

  /// Waits until `session` holds no pending permission request.
  ///
  /// - Parameter session: The session model that received the requests.
  /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled first.
  static func waitUntilNoPendingPermission(in session: SessionModel) async throws {
    try await ObservedValue.wait(for: "each permission request of the session ends") {
      session.pendingPermissions.isEmpty
    }
  }
}

import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A session has a set of capabilities, and the set is data. The root session
/// permits all methods. A child session permits only what it advertises in
/// `subagent_update.capabilities`. A method that the set does not know is
/// refused.
@Suite(.closesHarnesses) struct SessionCapabilityTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "SessionCapabilityTests"

  /// The text of the prompt that makes the root session listable.
  private static let rootPromptText = "Say hello."

  /// The text of the prompt that the test sends to the Router session of the child.
  private static let childPromptText = "Child, say hello."

  /// The name of a method that no session knows.
  private static let unknownMethod = "session/no_such_method"

  /// The methods that the client can send for a session, and that a child refuses.
  /// `session/fork`, `session/load` and `session/set_mode` are in the list too:
  /// the set refuses them, also when this agent has no handler for them.
  private static let refusedForChild = [
    ACPMethod.sessionPrompt, ACPMethod.sessionClose, ACPMethod.sessionDelete,
    ACPMethod.sessionResume, ACPMethod.sessionSetConfigOption,
    "session/fork", "session/load", "session/set_mode",
  ]

  /// The time the test waits for the record of the child to show its first activity.
  private static let activityDeadline: Duration = .seconds(30)

  /// The step of the wait for the record of the child.
  private static let activityPollStep: Duration = .milliseconds(20)

  /// Opens a fixture with one root session and one child below it.
  ///
  /// - Returns: The fixture and the id of the child.
  /// - Throws: Whatever the open of the fixture or of the child throws.
  private static func makeFixtureWithChild() async throws -> (ScriptedPromptFixture, SessionId) {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.textDelta("hello"), .endPass], label: label)
    let childId = try await SessionSetupNestedTests.openNestedSession(
      in: fixture, below: fixture.sessionId)
    return (fixture, childId)
  }

  /// Runs `call` and returns the refusal that it throws.
  ///
  /// - Parameter call: The request of the client.
  /// - Returns: The typed error, or `nil` when the call did not throw one.
  private static func refusal(of call: () async throws -> Void) async -> RequestError? {
    do {
      try await call()
      return nil
    } catch let error as RequestError {
      return error
    } catch {
      return nil
    }
  }

  /// Whether `error` is the refusal that names `method` and `sessionId`.
  ///
  /// - Parameters:
  ///   - error: The error of the request.
  ///   - method: The method that the refusal must name.
  ///   - sessionId: The session that the refusal must name.
  /// - Returns: `true` for the typed refusal of that method and session.
  private static func isRefusal(
    _ error: RequestError?, of method: String, on sessionId: SessionId
  ) -> Bool {
    guard let error else {
      return false
    }
    return error.code == .invalidParams
      && errorDataField("sessionId", of: error) == sessionId.rawValue
      && errorDataField("method", of: error) == method
  }

  // MARK: The sets

  /// The root session permits the prompt.
  @Test
  func theRootPermitsPrompt() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)

    let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])

    #expect(entry.capabilities.permits(ACPMethod.sessionPrompt))
    await fixture.close()
  }

  /// The root session permits a method that no one knew when the set was written.
  @Test
  func theRootPermitsAMethodThatItDoesNotKnow() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)

    let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])

    #expect(entry.capabilities.permits(Self.unknownMethod))
    await fixture.close()
  }

  /// A child permits `session/cancel`, because it advertises `cancel`.
  @Test
  func aChildPermitsCancel() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let entry = try #require(await fixture.harness.agent.sessions[childId])

    #expect(entry.capabilities.permits(ACPMethod.sessionCancel))
    await fixture.close()
  }

  /// A child permits none of the methods that it does not advertise.
  @Test
  func aChildPermitsNoMethodThatItDoesNotAdvertise() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let entry = try #require(await fixture.harness.agent.sessions[childId])

    #expect(Self.refusedForChild.filter { entry.capabilities.permits($0) }.isEmpty)
    await fixture.close()
  }

  /// A child refuses a method that the set does not know. The default is "not permitted".
  @Test
  func aChildRefusesAMethodThatTheSetDoesNotKnow() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let entry = try #require(await fixture.harness.agent.sessions[childId])

    #expect(!entry.capabilities.permits(Self.unknownMethod))
    await fixture.close()
  }

  /// The set of the child comes from the capabilities that the announcement advertises.
  @Test
  func theSetOfAChildIsTheSetThatTheAnnouncementAdvertises() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let entry = try #require(await fixture.harness.agent.sessions[childId])

    #expect(
      entry.capabilities == SessionCapabilitySet(advertised: SubagentAnnouncer.childCapabilities))
    await fixture.close()
  }

  // MARK: The refusals

  /// `session/prompt` on a child gives the typed refusal.
  @Test
  func promptOnAChildIsRefused() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let error = await Self.refusal {
      _ = try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: childId, text: Self.rootPromptText))
    }

    #expect(Self.isRefusal(error, of: ACPMethod.sessionPrompt, on: childId))
    await fixture.close()
  }

  /// `session/close` on a child gives the typed refusal.
  @Test
  func closeOnAChildIsRefused() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let error = await Self.refusal {
      _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: childId))
    }

    #expect(Self.isRefusal(error, of: ACPMethod.sessionClose, on: childId))
    await fixture.close()
  }

  /// A refused `session/close` leaves the child in the table and open.
  @Test
  func aRefusedCloseLeavesTheChildOpen() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    _ = await Self.refusal {
      _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: childId))
    }

    #expect(await fixture.harness.agent.sessions[childId]?.availability == .idle)
    await fixture.close()
  }

  /// `session/delete` on a child gives the typed refusal.
  @Test
  func deleteOnAChildIsRefused() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let error = await Self.refusal {
      _ = try await fixture.harness.connection.deleteSession(
        DeleteSessionRequest(sessionId: childId))
    }

    #expect(Self.isRefusal(error, of: ACPMethod.sessionDelete, on: childId))
    await fixture.close()
  }

  /// A refused `session/delete` leaves the entry of the child in the table.
  @Test
  func aRefusedDeleteLeavesTheEntryOfTheChild() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    _ = await Self.refusal {
      _ = try await fixture.harness.connection.deleteSession(
        DeleteSessionRequest(sessionId: childId))
    }

    #expect(await fixture.harness.agent.sessions[childId] != nil)
    await fixture.close()
  }

  /// `session/resume` on a child gives the typed refusal.
  @Test
  func resumeOnAChildIsRefused() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let error = await Self.refusal {
      _ = try await fixture.harness.connection.resumeSession(
        ResumeSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: childId))
    }

    #expect(Self.isRefusal(error, of: ACPMethod.sessionResume, on: childId))
    await fixture.close()
  }

  /// `session/set_config_option` on a child gives the typed refusal.
  @Test
  func setConfigOptionOnAChildIsRefused() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let error = await Self.refusal {
      _ = try await fixture.harness.connection.setSessionConfigOption(
        SetSessionConfigOptionRequest(
          configId: ConfigOptions.modelOptionId, sessionId: childId,
          value: .id(SessionConfigValueId(rawValue: ModelSlot.standard.rawValue))))
    }

    #expect(Self.isRefusal(error, of: ACPMethod.sessionSetConfigOption, on: childId))
    await fixture.close()
  }

  /// The refusal tells the method in words, so a client sees what it asked for.
  @Test
  func theRefusalNamesTheChildAndTheMethodInItsReason() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()

    let error = await Self.refusal {
      _ = try await fixture.harness.connection.closeSession(CloseSessionRequest(sessionId: childId))
    }

    let reason = try #require(error.flatMap { errorDataField("reason", of: $0) })
    #expect(reason.contains(ACPMethod.sessionClose))
    await fixture.close()
  }

  // MARK: The listing

  /// `session/list` never returns a child. The child has a record with
  /// activity, and the listing leaves it out.
  @Test
  func theListNeverReturnsAChild() async throws {
    let (fixture, childId) = try await Self.makeFixtureWithChild()
    try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.rootPromptText)
    let child = try #require(await fixture.harness.agent.sessions[childId])
    _ = try await child.session.send(Self.childPromptText)
    try await Self.waitForActivity(of: childId, in: fixture)

    let listed = try await fixture.harness.connection.listSessions(
      ListSessionsRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path)))

    #expect(listed.sessions.map(\.sessionId) == [fixture.sessionId])
    await fixture.close()
  }

  /// Waits until the record of the child shows its first activity, so the
  /// listing test cannot pass because the child was not yet recorded.
  ///
  /// - Parameters:
  ///   - childId: The child.
  ///   - fixture: The fixture that holds the child.
  /// - Throws: A failed requirement when the record shows no activity in time.
  private static func waitForActivity(
    of childId: SessionId, in fixture: ScriptedPromptFixture
  ) async throws {
    let entry = try #require(await fixture.harness.agent.sessions[childId])
    let root = entry.transcriptDirectory.deletingLastPathComponent()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: activityDeadline)
    while clock.now < deadline {
      let records = try RouterSessionDirectory.recordedSessions(in: root)
      let record = records.first { $0.sessionId.description == childId.rawValue }
      if record?.firstActivityAt != nil, record?.agentSpawn != nil {
        return
      }
      try await Task.sleep(for: activityPollStep)
    }
    Issue.record("the record of the child shows no activity")
  }
}

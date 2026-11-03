import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The end of a run that the client never learned of. The wire rule is that nothing about a child
/// goes out before its announcement. So the end of such a run sends no update of the child. It gives
/// the final status of the `agents` call out, and it drops the sends that the closed gate of the
/// child kept.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct SubagentSettleWireTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "SubagentSettleWireTests"

  /// The completion token of the `agents` call.
  private static let token = "01SETTLEWIRETESTCALLTOKEN1"

  /// The id that the SDK gives the call.
  private static let callId = ToolCallId(rawValue: "sdk-call-never-announced")

  /// A run that was never announced settles with no update of the child. The final status of its
  /// call goes out. The sends that the closed gate kept are dropped, and the child retires.
  @Test
  func aRunThatWasNeverAnnouncedSettlesWithNoUpdateOfTheChild() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent
    let root = fixture.sessionId
    let rootEntry = try #require(await agent.sessions[root])
    let childId = try await SessionSetupNestedTests.openNestedSession(in: fixture, below: root)
    let child = try #require(await agent.sessions[childId])
    let holds = rootEntry.projector.runCallJoins.holds
    rootEntry.projector.runCallJoins.record(toolCallID: Self.callId.rawValue, for: Self.token)
    holds.hold(Self.token)
    holds.runObserved(Self.token)
    await rootEntry.projector.commandSink(
      .toolCallUpdate(ToolCallUpdate(toolCallId: Self.callId, status: .value(.completed))))
    let kept = Task {
      await child.projector.commandSink(SessionSetupNestedTests.makeMessageUpdate())
    }
    while child.announcement.pendingCount == 0 {
      await Task.yield()
    }
    let report = SubagentReport(
      runID: child.session.id, caller: nil, title: "worker", description: nil,
      state: .idle(IdleStateUpdate(stopReason: .endTurn)), completionToken: Self.token)

    await agent.settleSubagent(report, root: root, holds: holds)

    await kept.value
    let updates = try await fixture.collector.wait(for: "the final status of the call") { updates in
      updates.contains {
        $0.sessionId == root && ChildSessionProjectionTests.isFinal($0.update, of: Self.callId)
      }
    }
    #expect(!updates.contains { $0.sessionId == childId })
    #expect(child.announcement.droppedSendCount == 1)
    #expect(await agent.sessions[childId] == nil)
    await fixture.close()
  }
}

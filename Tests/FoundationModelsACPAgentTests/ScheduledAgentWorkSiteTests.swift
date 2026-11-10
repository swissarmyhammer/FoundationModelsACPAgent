import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A scheduled agent that a resume restores holds a lease in the work
/// registry of its root session while it fires. Without the lease, a session
/// whose only work is a restored firing shows no work, so a headless run can
/// exit and the idle notice can say `noWork` too early.
@Suite struct ScheduledAgentWorkSiteTests {
  /// The work site of a restore opens a child-session lease on the root
  /// session, with the id that the scheduler gives it.
  @Test func theWorkSiteOfARestoreOpensAChildSessionLeaseOnTheRootSession() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [], label: "ScheduledAgentWorkSiteTests")
    let entry = await fixture.harness.agent.sessions[fixture.sessionId]
    let root = CloseCountingRoutedSession(wrapping: try #require(entry?.session))

    let lease = RoutedACPAgent.scheduledAgentWorkSite(of: root)("firing-1")
    lease.end()

    #expect(root.backgroundWork.map(\.kind) == [.childSession])
    #expect(root.backgroundWork.map(\.id) == ["firing-1"])
    await fixture.close()
  }
}

import FoundationModelsRouter
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

// MARK: - The close of a session that the selection factory makes
//
// The skills selection tier calls its session factory one time for the
// cached root of the tier, and one time for each run of an over-budget
// search. Each call makes a new guided Router session, and each one keeps
// a prompt cache entry until something closes it. These cases prove that
// a factory session closes one time when the tier drops it, and that a
// held root stays open while the tier forks it.

/// The close of the Router sessions that
/// `OwnedSelectionSession.factory(makingEach:)` wraps.
@Suite
struct OwnedSelectionSessionTests {
    /// The request that each test gives the factory. The test factory does
    /// not read it.
    private static let instructions = "the assembled prefix of the tier"

    /// The factory under test, the double that each factory call gives,
    /// and the wire fixture that owns the real Router session.
    private struct Factory {
        /// The factory under test. Each call wraps ``routed``.
        let make: @Sendable (String) -> any AgentSession

        /// The double over a fork of the real Router session.
        let routed: CloseCountingRoutedSession

        /// The wire fixture that owns the real Router session.
        let fixture: ScriptedTurnFixture
    }

    /// Opens one scripted session, forks its Router session, and makes a
    /// factory that wraps a close counter over the fork.
    ///
    /// The double wraps a fork, not the session of the fixture, so a close
    /// through the factory does not close the session that the fixture
    /// closes at the end.
    ///
    /// - Returns: The factory, the double and the fixture.
    /// - Throws: Whatever the fixture construction or the fork throws.
    private static func makeFactory() async throws -> Factory {
        let fixture = try await ScriptedTurnFixture.make(
            script: [.endTurn], label: "OwnedSelectionSessionTests")
        let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
        let routed = CloseCountingRoutedSession(
            wrapping: try await session.fork(workingDirectory: nil))
        let make = OwnedSelectionSession.factory(makingEach: { (_: String) in routed })
        return Factory(make: make, routed: routed, fixture: fixture)
    }

    /// Makes one session through `factory`, and checks that its Router
    /// session stays open while the session is held. The session is
    /// dropped on return.
    ///
    /// - Parameter factory: The factory under test.
    private static func makeHoldAndDrop(_ factory: Factory) async {
        let session = factory.make(Self.instructions)
        #expect(await factory.routed.closeCount == 0, "a held session must stay open")
        withExtendedLifetime(session) {}
    }

    /// When the tier drops a session that the factory made, its Router
    /// session closes one time.
    @Test(.timeLimit(.minutes(1)))
    func aFactorySessionIsClosedWhenItsWorkEnds() async throws {
        let factory = try await Self.makeFactory()

        await Self.makeHoldAndDrop(factory)
        try await Poll.until("the dropped session is closed") { await factory.routed.closeCount > 0 }

        #expect(await factory.routed.closeCount == 1)
        await factory.fixture.close()
    }

    /// A held root stays open after the tier forks it and drops the child,
    /// and it closes one time when the tier drops it.
    @Test(.timeLimit(.minutes(1)))
    func aHeldRootStaysOpenWhileTheTierForksIt() async throws {
        let factory = try await Self.makeFactory()
        var root: (any AgentSession)? = factory.make(Self.instructions)

        try await Self.forkAndDrop(try #require(root))
        let child = try #require(await factory.routed.forks.first)
        try await Poll.until("the dropped child is closed") { await child.closeCount > 0 }
        #expect(await factory.routed.closeCount == 0, "a held root must stay open")

        root = nil
        try await Poll.until("the dropped root is closed") { await factory.routed.closeCount > 0 }
        #expect(await factory.routed.closeCount == 1)
        await factory.fixture.close()
    }

    /// Forks `root` one time, as the tier does for each search, and drops
    /// the child on return.
    ///
    /// - Parameter root: The root session to fork.
    /// - Throws: Whatever the fork throws.
    private static func forkAndDrop(_ root: any AgentSession) async throws {
        let child = try await root.fork()
        withExtendedLifetime(child) {}
    }
}

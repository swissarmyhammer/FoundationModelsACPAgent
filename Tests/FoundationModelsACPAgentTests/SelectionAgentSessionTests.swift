import FoundationModelsRouter
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

// MARK: - The close of a selection fork
//
// The skills selection tier forks its root session one time for each
// search, and then drops the child. The Router fork under that child
// keeps a prompt cache entry until something closes it. These cases
// prove that the fork closes one time when its work ends, and that the
// close of a fork does not close the parent.

/// The close of the Router forks that `SelectionAgentSession.fork()` makes.
@Suite
struct SelectionAgentSessionTests {
    /// The parent double, the selection session over it, and the wire
    /// fixture that owns the real Router session.
    private struct Parent {
        /// The double over the real Router session.
        let routed: CloseCountingRoutedSession

        /// The selection session under test, over ``routed``.
        let selection: SelectionAgentSession

        /// The wire fixture that owns the real Router session.
        let fixture: ScriptedPromptFixture
    }

    /// Opens one scripted session and wraps its Router session in a
    /// close counter.
    ///
    /// - Returns: The parent double, the selection session and the fixture.
    /// - Throws: Whatever the fixture construction throws.
    private static func makeParent() async throws -> Parent {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.endPass], label: "SelectionAgentSessionTests")
        let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
        let routed = CloseCountingRoutedSession(wrapping: session)
        return Parent(routed: routed, selection: SelectionAgentSession(session: routed), fixture: fixture)
    }

    /// Forks `selection` one time, and checks that the Router fork stays
    /// open while the child is held. The child is dropped on return.
    ///
    /// - Parameters:
    ///   - selection: The selection session to fork.
    ///   - routed: The double under `selection`.
    /// - Returns: The double over the Router fork.
    /// - Throws: Whatever the fork throws, or when no fork was recorded.
    private static func forkHoldAndDrop(
        _ selection: SelectionAgentSession, over routed: CloseCountingRoutedSession
    ) async throws -> CloseCountingRoutedSession {
        let child = try await selection.fork()
        let fork = try #require(await routed.forks.first)
        #expect(await fork.closeCount == 0, "a held fork must stay open")
        withExtendedLifetime(child) {}
        return fork
    }

    /// When the tier drops the child, its Router fork closes one time.
    @Test(.timeLimit(.minutes(1)))
    func aForkIsClosedWhenItsWorkEnds() async throws {
        let parent = try await Self.makeParent()

        let fork = try await Self.forkHoldAndDrop(parent.selection, over: parent.routed)
        try await Poll.until("the dropped fork is closed") { await fork.closeCount > 0 }

        #expect(await parent.routed.forks.count == 1)
        #expect(await fork.closeCount == 1)
        await parent.fixture.close()
    }

    /// The close of a fork does not close the parent session.
    @Test(.timeLimit(.minutes(1)))
    func closingAForkKeepsTheParentOpen() async throws {
        let parent = try await Self.makeParent()

        let fork = try await Self.forkHoldAndDrop(parent.selection, over: parent.routed)
        try await Poll.until("the dropped fork is closed") { await fork.closeCount > 0 }

        #expect(await parent.routed.closeCount == 0)
        await parent.fixture.close()
    }
}

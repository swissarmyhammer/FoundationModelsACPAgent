import FoundationModelsACPAgentTestSupport
import Synchronization
import Testing

/// Test rule T1 (elicitation-plan.md section 10): a fixture closes also
/// when the test body throws. The ``ClosesHarnessesTrait`` does this for
/// each harness. Each test runs the scope of the trait directly around a
/// body, inside this test.
@Suite struct ClosesHarnessesTraitTests {
    /// The error that the body throws.
    private struct BodyFailed: Error {}

    /// The harness that a body made, so the test can read it after the
    /// scope.
    private final class MadeHarness: Sendable {
        /// The harness, or `nil` before the body made it.
        let harness = Mutex<AgentClientHarness?>(nil)
    }

    /// Runs the scope of the trait around `body`, in the test that runs
    /// now.
    ///
    /// - Parameter body: The body.
    /// - Throws: What the scope throws.
    private static func runScope(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let test = try #require(Test.current)
        try await ClosesHarnessesTrait().provideScope(
            for: test, testCase: Test.Case.current, performing: body)
    }

    /// A body that makes a harness and throws: the scope closes the
    /// harness, and the error goes on.
    @Test func aHarnessOfABodyThatThrowsIsClosed() async throws {
        let made = MadeHarness()
        await #expect(throws: BodyFailed.self) {
            try await Self.runScope {
                let harness = try await AgentClientHarness.make()
                made.harness.withLock { $0 = harness }
                throw BodyFailed()
            }
        }
        let harness = try #require(made.harness.withLock { $0 })

        #expect(harness.lifetime.isClosed)
    }

    /// A body that returns closes its own harness. The scope does not
    /// close a harness after a body that returns.
    @Test func aHarnessOfABodyThatReturnsIsNotClosedByTheScope() async throws {
        let made = MadeHarness()
        try await Self.runScope {
            let harness = try await AgentClientHarness.make()
            made.harness.withLock { $0 = harness }
        }
        let harness = try #require(made.harness.withLock { $0 })
        let closedByScope = harness.lifetime.isClosed
        await harness.close()

        #expect(!closedByScope)
        #expect(harness.lifetime.isClosed)
    }
}

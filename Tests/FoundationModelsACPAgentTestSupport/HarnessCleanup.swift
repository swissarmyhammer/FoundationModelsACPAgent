import Synchronization
import Testing

// MARK: - The close of each harness of a test (test rule T1)
//
// Test rule T1 (elicitation-plan.md section 10): each test fixture closes
// its sessions also when the test body throws. Each fixture of this target
// wraps one ``AgentClientHarness``. The ``ClosesHarnessesTrait`` keeps each
// harness that a test makes, and closes it when the test body throws. A
// harness closes one time: a second ``close()`` does nothing, so a close in
// the test body and the close of the trait do not collide.

/// The close state of one ``AgentClientHarness``. The harness is a value,
/// so its copies share this one box.
public final class HarnessLifetime: Sendable {
    /// Whether a close started.
    private let closed = Mutex(false)

    /// Makes the state of a harness that is open.
    public init() {}

    /// Whether a close started.
    public var isClosed: Bool {
        closed.withLock { $0 }
    }

    /// Marks the harness as closed.
    ///
    /// - Returns: `true` for the first call, and `false` for each later
    ///   call.
    public func markClosed() -> Bool {
        closed.withLock { closed in
            defer { closed = true }
            return !closed
        }
    }
}

/// The harnesses that one test made, in the order of their make.
public final class HarnessRegistry: Sendable {
    /// The registry of the test that runs now, or `nil` outside a test
    /// with the ``ClosesHarnessesTrait``.
    @TaskLocal public static var current: HarnessRegistry?

    /// The harnesses of the test.
    private let harnesses = Mutex<[AgentClientHarness]>([])

    /// Makes an empty registry.
    public init() {}

    /// Keeps `harness`, so ``closeAll()`` closes it.
    ///
    /// - Parameter harness: The harness that the test made.
    public func add(_ harness: AgentClientHarness) {
        harnesses.withLock { $0.append(harness) }
    }

    /// Lets go of the harness of `lifetime`. A harness that closed needs no
    /// close of the trait, and a test can then wait for the release of its
    /// agent.
    ///
    /// - Parameter lifetime: The close state of the harness.
    public func remove(_ lifetime: HarnessLifetime) {
        harnesses.withLock { harnesses in
            harnesses.removeAll { $0.lifetime === lifetime }
        }
    }

    /// Lets go of each kept harness. The tasks of an agent keep the task
    /// local of the test, and with it this registry. Thus the registry must
    /// not keep a harness, and its agent and models, after the test.
    public func removeAll() {
        harnesses.withLock { $0.removeAll() }
    }

    /// Closes each kept harness, in the reverse order of their make, and
    /// then lets go of them.
    public func closeAll() async {
        for harness in harnesses.withLock({ $0 }).reversed() {
            await harness.close()
        }
        removeAll()
    }
}

/// The trait that closes each harness of each test of a suite when the
/// test body throws (test rule T1).
///
/// Give it to a suite with `@Suite(.closesHarnesses)`. It applies to each
/// test of the suite, and to each case of a parameterized test.
public struct ClosesHarnessesTrait: SuiteTrait, TestTrait, TestScoping {
    /// The trait applies to each test of the suite.
    public var isRecursive: Bool { true }

    /// Makes the trait.
    public init() {}

    /// Gives a scope to each test case only, and not to the suite: a
    /// harness belongs to the one test that made it.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    /// Runs the test with a new ``HarnessRegistry``. When the test throws,
    /// it closes each harness that the test made, and then the error goes
    /// on.
    ///
    /// A test that returns closes its own harnesses. Some tests keep a run
    /// open on purpose until the test ends, and a close of such a harness
    /// waits for that run. Thus the trait does not close after a test that
    /// returns.
    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        let registry = HarnessRegistry()
        do {
            try await HarnessRegistry.$current.withValue(registry) {
                try await function()
            }
        } catch {
            await registry.closeAll()
            throw error
        }
        registry.removeAll()
    }
}

extension Trait where Self == ClosesHarnessesTrait {
    /// Closes each harness of each test when the test body throws (test
    /// rule T1).
    public static var closesHarnesses: Self { Self() }
}

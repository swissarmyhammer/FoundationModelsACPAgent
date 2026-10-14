import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras

// MARK: - The waits for the release of an actor

// The agent and the Router session are actors. An actor allows no
// associated object, and the agent has no deinit hook, so a test cannot see
// the deinit of either one directly. Each wait below watches a test object
// that only the watched actor (and what it owns) holds. The deinit of that
// object thus follows the release of the actor, and the wait uses no clock
// and no poll.

/// A command provider whose deinit is the event of the release of the
/// agent that registered it.
///
/// The test registers it with `RoutedACPAgent.registerCommandProviders(_:)`
/// and keeps no reference to it. These objects hold it:
///
/// - the agent, in its `commandProviders` list;
/// - the `CommandRegistry` of each session of the agent. The session entry
///   in the session table of the agent holds the registry. The builtin
///   command context holds the registry weakly, so no cycle keeps it.
///
/// The provider gives no `commandUpdates` stream, so no follower task of a
/// registry holds it. Thus the provider goes only when the agent and each
/// session entry of the agent went, and the agent holds its session
/// entries until it goes.
final class AgentReleaseSentinel: SlashCommandProviding {
    /// Whether the provider was released, with its waits. The test keeps
    /// this value; the provider only sets it.
    private let released: WatchedValue<Bool>

    /// Makes a sentinel that sets `released` in its deinit.
    ///
    /// - Parameter released: The value the deinit sets to `true`.
    init(settingOnRelease released: WatchedValue<Bool>) {
        self.released = released
    }

    deinit {
        released.update { $0 = true }
    }

    func commands(workingDirectory: URL) async -> [SlashCommand] {
        []
    }

    var commandUpdates: AsyncStream<[SlashCommand]>? {
        nil
    }

    /// Makes a sentinel and the value its release sets.
    ///
    /// - Returns: The sentinel to register, and the value the test waits on.
    static func make() -> (sentinel: AgentReleaseSentinel, released: WatchedValue<Bool>) {
        let released = WatchedValue(false)
        return (AgentReleaseSentinel(settingOnRelease: released), released)
    }
}

/// The wait for the release of the Router sessions of a scripted model.
///
/// A Router session holds its backend while the session lives, so the
/// release of each scripted backend (``BackendLifetimes``) follows the
/// release of each session. The proxy is sound only when no backend was
/// replaced while a session lived: a compaction or a watch stop gives a
/// session a new backend and releases the old one. A test that uses this
/// wait thus also expects that no compaction ran on the session.
enum RouterSessionReleaseWatch {
    /// Waits until no scripted backend of `lifetimes` is alive.
    ///
    /// - Parameter lifetimes: The count of the scripted backends.
    /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled
    ///   first.
    static func waitForRelease(of lifetimes: BackendLifetimes) async throws {
        try await lifetimes.wait(for: "each scripted backend is released") { $0 == 0 }
    }
}

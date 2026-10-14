/// The count of the scripted backends of a model that are alive now.
///
/// Each ``ScriptedSessionBackend`` that a container with this count makes,
/// and each fork or replaced transcript of it, adds one when it is made and
/// takes one away in its `deinit`. A test waits for a count with
/// ``wait(for:until:)``: each change resumes the waits whose condition is
/// now true, so the wait uses no clock and no poll.
///
/// A Router session holds its backend while the session lives. A test uses
/// the release of the backends as the event of the release of the session,
/// which is an actor and thus has no event of its own.
public final class BackendLifetimes: Sendable {
    /// The number of backends that are alive, with its waits.
    private let alive = WatchedValue(0)

    /// The number of backends that were made, alive or not.
    private let made = WatchedValue(0)

    /// Creates a count with no backend.
    public init() {}

    /// The number of backends that are alive now.
    public var aliveCount: Int {
        alive.value
    }

    /// The number of backends that were made so far.
    public var madeCount: Int {
        made.value
    }

    /// Waits until `isMet` is true for the number of backends that are
    /// alive. Returns at once when it is true now.
    ///
    /// - Parameters:
    ///   - condition: The name of the condition, for the error of a
    ///     cancelled wait.
    ///   - isMet: Tells if the condition is true for the count.
    /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
    ///   cancelled before the condition comes.
    public func wait(for condition: String, until isMet: @escaping @Sendable (Int) -> Bool) async throws {
        _ = try await alive.wait(for: condition, until: isMet)
    }

    /// Counts one backend that was made.
    func backendMade() {
        made.update { $0 += 1 }
        alive.update { $0 += 1 }
    }

    /// Counts one backend that was released.
    func backendReleased() {
        alive.update { $0 -= 1 }
    }
}

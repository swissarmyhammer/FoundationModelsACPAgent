import FoundationModelsACP
import Synchronization

/// The open `_sah/graphql/subscribe` subscriptions of the agent (ACPA-13):
/// one task for each subscription, keyed by its connection and its id. A
/// subscription id is unique for each connection (ACP-5), so two
/// connections can use the same id.
///
/// The task of a subscription runs the stream of its endpoint and sends its
/// notifications. `_sah/graphql/unsubscribe` cancels it, and so does the
/// close of its connection (``cancelAll(of:)``). A `Mutex` holds the table,
/// because the unsubscribe notification is served in the read loop of the
/// connection and must return at once.
final class GraphQLTunnelSubscriptions: Sendable {
    /// The key of one subscription: its connection and its id.
    struct Key: Hashable, Sendable {
        /// The connection that started the subscription.
        let connection: ConnectionId

        /// The id that the client gave the subscription.
        let subscription: SAH.GraphQL.SubscriptionId
    }

    /// One open subscription.
    private struct Entry {
        /// The number of the start that made this entry. The end of a task
        /// removes only its own entry, not a later one with the same key.
        let generation: Int

        /// The task that runs the subscription.
        let task: Task<Void, Never>
    }

    /// The open subscriptions and the number of the next start.
    private struct State {
        /// The open subscriptions.
        var entries: [Key: Entry] = [:]

        /// The number of the next start.
        var nextGeneration = 0
    }

    /// The table, under its lock.
    private let state = Mutex(State())

    /// Starts one subscription, unless its key is in use.
    ///
    /// The task starts under the lock, so it cannot end, and remove its
    /// entry, before the entry is in the table.
    ///
    /// - Parameters:
    ///   - key: The key of the subscription.
    ///   - run: Runs the subscription. It gets the generation that
    ///     ``finish(_:generation:)`` takes at its end.
    /// - Returns: `false` when an open subscription already has `key`; then
    ///   nothing starts.
    func start(_ key: Key, run: @escaping @Sendable (_ generation: Int) async -> Void) -> Bool {
        state.withLock { state in
            guard state.entries[key] == nil else {
                return false
            }
            let generation = state.nextGeneration
            state.nextGeneration += 1
            state.entries[key] = Entry(generation: generation, task: Task { await run(generation) })
            return true
        }
    }

    /// Removes the entry of a subscription whose task ends. An entry of a
    /// later start with the same key stays.
    ///
    /// - Parameters:
    ///   - key: The key of the subscription.
    ///   - generation: The generation that ``start(_:run:)`` gave the task.
    func finish(_ key: Key, generation: Int) {
        state.withLock { state in
            if state.entries[key]?.generation == generation {
                state.entries.removeValue(forKey: key)
            }
        }
    }

    /// Cancels one subscription and removes it. A key with no open
    /// subscription does nothing.
    ///
    /// - Parameter key: The key of the subscription.
    func cancel(_ key: Key) {
        state.withLock { $0.entries.removeValue(forKey: key) }?.task.cancel()
    }

    /// Cancels and removes each subscription of one connection: its
    /// connection closed, so no notification can reach the client.
    ///
    /// - Parameter connection: The connection that closed.
    func cancelAll(of connection: ConnectionId) {
        let removed = state.withLock { state in
            let keys = state.entries.keys.filter { $0.connection == connection }
            return keys.compactMap { state.entries.removeValue(forKey: $0) }
        }
        for entry in removed {
            entry.task.cancel()
        }
    }
}

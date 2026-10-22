import FoundationModelsACP
import Synchronization

/// The open `_sah/graphql/subscribe` subscriptions of the agent (ACPA-13):
/// one task for each subscription, grouped by its connection and keyed by its
/// id. A subscription id is unique for each connection (ACP-5), so two
/// connections can use the same id.
///
/// The task of a subscription runs the stream of its endpoint and sends its
/// notifications. `_sah/graphql/unsubscribe` cancels it, and so does the
/// close of its connection (``cancelAll(of:)``). A `Mutex` holds the table,
/// because the unsubscribe notification is served in the read loop of the
/// connection and must return at once.
final class GraphQLTunnelSubscriptions: Sendable {
    /// One open subscription.
    private struct Entry {
        /// The number of the start that made this entry. The end of a task
        /// removes only its own entry, not a later one with the same id.
        let generation: Int

        /// The task that runs the subscription.
        let task: Task<Void, Never>
    }

    /// The open subscriptions and the number of the next start.
    private struct State {
        /// The open subscriptions of each connection, by subscription id.
        var entries: [ConnectionId: [SAH.GraphQL.SubscriptionId: Entry]] = [:]

        /// The number of the next start.
        var nextGeneration = 0

        /// Removes one entry, and the group of its connection when that
        /// group is empty after it.
        ///
        /// - Parameter id: The id of the subscription.
        /// - Parameter connection: The connection that started the subscription.
        /// - Returns: The removed entry, or `nil` when there is none.
        mutating func remove(_ id: SAH.GraphQL.SubscriptionId, of connection: ConnectionId) -> Entry? {
            let removed = entries[connection]?.removeValue(forKey: id)
            if entries[connection]?.isEmpty == true {
                entries.removeValue(forKey: connection)
            }
            return removed
        }
    }

    /// The table, under its lock.
    private let state = Mutex(State())

    /// Starts one subscription, unless its connection has an open one with
    /// the same id.
    ///
    /// The task starts under the lock, so it cannot end, and remove its
    /// entry, before the entry is in the table.
    ///
    /// - Parameter id: The id that the client gave the subscription.
    /// - Parameter connection: The connection that starts the subscription.
    /// - Parameter run: Runs the subscription. It gets the generation that
    ///   ``finish(_:of:generation:)`` takes at its end.
    /// - Returns: `false` when an open subscription of `connection` already
    ///   has `id`; then nothing starts.
    func start(
        _ id: SAH.GraphQL.SubscriptionId, of connection: ConnectionId,
        run: @escaping @Sendable (_ generation: Int) async -> Void
    ) -> Bool {
        state.withLock { state in
            guard state.entries[connection]?[id] == nil else {
                return false
            }
            let generation = state.nextGeneration
            state.nextGeneration += 1
            state.entries[connection, default: [:]][id] = Entry(
                generation: generation, task: Task { await run(generation) })
            return true
        }
    }

    /// Removes the entry of a subscription whose task ends. An entry of a
    /// later start with the same id stays.
    ///
    /// - Parameter id: The id of the subscription.
    /// - Parameter connection: The connection that started the subscription.
    /// - Parameter generation: The generation that ``start(_:of:run:)`` gave the task.
    func finish(_ id: SAH.GraphQL.SubscriptionId, of connection: ConnectionId, generation: Int) {
        state.withLock { state in
            if state.entries[connection]?[id]?.generation == generation {
                _ = state.remove(id, of: connection)
            }
        }
    }

    /// Cancels one subscription and removes it. An id with no open
    /// subscription on `connection` does nothing.
    ///
    /// - Parameter id: The id of the subscription.
    /// - Parameter connection: The connection that started the subscription.
    func cancel(_ id: SAH.GraphQL.SubscriptionId, of connection: ConnectionId) {
        state.withLock { $0.remove(id, of: connection) }?.task.cancel()
    }

    /// Cancels and removes each subscription of one connection: its
    /// connection closed, so no notification can reach the client.
    ///
    /// - Parameter connection: The connection that closed.
    func cancelAll(of connection: ConnectionId) {
        let removed = state.withLock { $0.entries.removeValue(forKey: connection) } ?? [:]
        for entry in removed.values {
            entry.task.cancel()
        }
    }
}

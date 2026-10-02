import FoundationModelsExtras

/// The check that a live-model test gives its models back to the model pool
/// of the process.
///
/// **Why a test must give its models back.** Each Router of the process
/// resolves into the one `ModelPool.shared`. A resolve subtracts the bytes of
/// each resident model from the memory budget, and then fits its models into
/// what is left. When the native window does not fit, the first resolve sizes
/// its window to the whole budget. On the CI machine on 2026-10-02 that left
/// 176359 bytes. Thus a suite that keeps its agent keeps its models, and the
/// next live-model suite of the process cannot resolve (task `^173qn8n`). On a
/// machine with more memory the native window fits with memory left, and the
/// same leak does not fail. The budget does not show the leak there, but the
/// pool does.
///
/// **What releases the models.** `RoutedACPAgent.residentProfile` keeps a hold
/// of each model of the profile for the life of the agent. When the last
/// reference to the agent goes, each hold goes, and the pool evicts the models
/// in its admission queue.
enum ProcessModelPool {
    /// The pause between two looks at the pool.
    private static let pollInterval: Duration = .milliseconds(100)

    /// How long a look waits for the pool to evict the last model. An
    /// eviction is a job in the admission queue, and it frees the memory of
    /// a loaded model, so it is short. The deadline is a guard against a
    /// model that stays, not a budget.
    static let deadline: Duration = .seconds(60)

    /// Waits until the pool of the process holds no model, or until
    /// ``deadline``.
    ///
    /// - Returns: The models the pool still holds: empty when the pool
    ///   evicted each model before the deadline.
    static func residentModelsAfterRelease() async -> [ModelPoolKey] {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            if ModelPool.shared.footprint.resident.isEmpty {
                return []
            }
            try? await Task.sleep(for: pollInterval)
        }
        return Array(ModelPool.shared.footprint.resident.keys)
    }

    /// One line for a failed check: the models the pool still holds.
    ///
    /// - Parameter keys: The models the pool still holds.
    /// - Returns: The model names and roles, sorted.
    static func describe(_ keys: [ModelPoolKey]) -> String {
        keys.map { "\($0.ref.stringValue) (\($0.role))" }.sorted().joined(separator: ", ")
    }
}

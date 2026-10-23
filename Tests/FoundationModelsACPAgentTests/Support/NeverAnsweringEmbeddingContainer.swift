import FoundationModelsRouter

/// An embedding container that never answers. `embed(texts:)` waits until
/// its task is cancelled, and then it throws the cancellation.
///
/// A code context over it never ends its first index pass by itself, so the
/// end of that pass shows that the context was stopped.
final class NeverAnsweringEmbeddingContainer: LoadedEmbeddingContainer {
    /// An arbitrary vector length; no vector is ever made.
    let dimension = 8

    /// Waits for the cancellation of the task.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await waitForCancellation()
        return []
    }
}

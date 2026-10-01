import FoundationModelsCodeContext
import FoundationModelsRouter

/// Presents a Router embedding handle as the `TextEmbedding` the code
/// context package embeds with.
///
/// `TextEmbedding` declares one member, `embed(_:)`. This type forwards it
/// and adds nothing: no batching and no error mapping. `TextEmbedding`
/// declares no vector length, because each vector carries its own length.
/// Thus this type does not read the `dimension` of the handle. Multitool
/// holds an adapter of the same shape for its own searcher; each consumer
/// keeps its own.
struct ProfileTextEmbedding: FoundationModelsCodeContext.TextEmbedding {
    /// The Router handle every embed travels to.
    private let embedder: RoutedEmbedder

    /// Makes the presentation over one Router embedding handle.
    ///
    /// - Parameter embedder: The resolved, resident handle to present.
    init(embedder: RoutedEmbedder) {
        self.embedder = embedder
    }

    /// Embeds each text into one vector, in order. All the vectors have the
    /// same length.
    ///
    /// - Parameter texts: The texts to embed.
    /// - Returns: One vector per text, in the same order.
    /// - Throws: Whatever the handle throws.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await embedder.embed(texts: texts)
    }
}

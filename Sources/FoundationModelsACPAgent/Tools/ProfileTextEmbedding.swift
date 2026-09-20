import FoundationModelsCodeContext
import FoundationModelsRouter

/// Presents a Router embedding handle as the `TextEmbedding` the code
/// context package embeds with.
///
/// The two protocols have the same shape, so this type forwards both
/// members and adds nothing: no batching and no error mapping. Multitool
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

    /// The length of every vector the handle answers.
    var dimension: Int { embedder.dimension }

    /// Embeds each text into one `dimension`-length vector, in order.
    ///
    /// - Parameter texts: The texts to embed.
    /// - Returns: One vector per text, in the same order.
    /// - Throws: Whatever the handle throws.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await embedder.embed(texts: texts)
    }
}

import FoundationModelsRouter

/// Presents a Router embedding handle as the `PooledEmbedding` that the
/// code context package and the Multitool searchers embed with.
///
/// `PooledEmbedding` declares one member, `embed(texts:)`. This type
/// forwards it and adds nothing: no batching and no error mapping. A
/// wrapper, and not a conformance of the Router type: an extension that
/// conforms a type of one package to a protocol of another package is a
/// retroactive conformance, which a later release of either package can
/// break.
struct ProfileEmbedding: PooledEmbedding {
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
    func embed(texts: [String]) async throws -> [[Float]] {
        try await embedder.embed(texts: texts)
    }
}

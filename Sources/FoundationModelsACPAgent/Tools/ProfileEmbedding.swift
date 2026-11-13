import FoundationModelsMultitool
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
///
/// The type also conforms to `IdentifiedEmbedding`, thus the Multitool
/// search index cache knows that two values over one handle are the same
/// embedder. Each session makes a new value of this type, and a struct has
/// no identity of its own. Without the conformance, each session embeds the
/// whole tool catalog again.
struct ProfileEmbedding: IdentifiedEmbedding {
  /// The Router handle every embed travels to.
  private let embedder: RoutedEmbedder

  /// Makes the presentation over one Router embedding handle.
  ///
  /// - Parameter embedder: The resolved, resident handle to present.
  init(embedder: RoutedEmbedder) {
    self.embedder = embedder
  }

  /// The Router handle that this value presents: the object that tells the
  /// search index cache which embedders are the same.
  ///
  /// This owner is safe for the cache:
  ///
  /// - `RoutedEmbedder` is `RoutedModel`, a final class with `let chosen`
  ///   and `let container`. Thus one handle cannot change its model, and it
  ///   always gives the same vector for the same text. A profile change
  ///   resolves a new `RoutedModel`, and thus a new owner.
  /// - The cache holds the owner with a weak reference only. Thus the cache
  ///   does not keep a released profile alive: when the last session of the
  ///   profile ends, the profile frees its models.
  var embeddingOwner: any AnyObject & Sendable {
    embedder
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

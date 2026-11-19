import FoundationModelsExtras
import Synchronization

/// A fake embedder that counts the texts that it embeds, with the vectors of
/// ``WordBucketEmbedding``.
///
/// A test of the persistence of the transcript search reads ``embeddedTextCount`` to know if the
/// searcher embedded its items again. The measurement of the `Benchmarks` package gives a cost for
/// each text, so that each embed takes a fixed time, as a small real model does.
public final class CountingEmbedding: PooledEmbedding, Sendable {
  /// The embedder that makes the vectors.
  private let vectors = WordBucketEmbedding()

  /// The time that the embed of one text takes.
  private let costPerText: Duration

  /// The number of texts that the embedder embedded.
  private let count = Mutex(0)

  /// Makes an embedder.
  ///
  /// - Parameter costPerText: The time that the embed of one text takes. The default is no time.
  public init(costPerText: Duration = .zero) {
    self.costPerText = costPerText
  }

  /// The number of texts that the embedder embedded.
  public var embeddedTextCount: Int {
    count.withLock { $0 }
  }

  /// Embeds each text, counts the texts, and waits for the cost of the texts.
  ///
  /// - Parameter texts: The texts to embed.
  /// - Returns: One vector for each text, in order.
  /// - Throws: The cancel of the wait.
  public func embed(texts: [String]) async throws -> [[Float]] {
    count.withLock { $0 += texts.count }
    if costPerText > .zero {
      try await Task.sleep(for: costPerText * texts.count)
    }
    return try await vectors.embed(texts: texts)
  }
}

import FoundationModelsExtras
import FoundationModelsMetadataRegistry

/// A fake embedder of the transcript search tests: a text gives a vector with one count for each
/// bucket of its words.
///
/// A word goes into the bucket of the sum of its Unicode scalars, so the same word always goes
/// into the same bucket, also in a different process. Two texts with the same words give the same
/// vector, and a text gives a high cosine score to a query with its words. The words are the
/// tokens of the ranker (`Tokenizer.tokenize(text:)`), as the keyword signals read them.
public struct WordBucketEmbedding: PooledEmbedding {
  /// The number of buckets: the length of each vector.
  private static let bucketCount = 64

  /// Makes the embedder. It has no state.
  public init() {}

  /// Embeds each text as the counts of the buckets of its words.
  ///
  /// - Parameter texts: The texts to embed.
  /// - Returns: One vector for each text, in order.
  public func embed(texts: [String]) async throws -> [[Float]] {
    texts.map(Self.vector(of:))
  }

  /// The counts of the buckets of the words of one text.
  ///
  /// - Parameter text: The text.
  /// - Returns: The vector.
  private static func vector(of text: String) -> [Float] {
    Tokenizer.tokenize(text: text).reduce(into: [Float](repeating: .zero, count: bucketCount)) {
      counts, word in
      counts[bucket(of: word)] += 1
    }
  }

  /// The bucket of one word.
  ///
  /// - Parameter word: The word.
  /// - Returns: The index of the bucket.
  private static func bucket(of word: String) -> Int {
    word.unicodeScalars.reduce(0) { sum, scalar in sum + Int(scalar.value) } % bucketCount
  }
}

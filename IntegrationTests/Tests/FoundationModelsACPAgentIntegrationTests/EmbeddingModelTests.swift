import Foundation
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import FoundationModelsRouterTestSupport
import Testing

/// Proves that a profile loads and uses a REAL embedding model of each
/// format: the Core ML model on the Apple Neural Engine (the shipped
/// default) and the MLX Qwen embedding model.
///
/// The settings select a builtin profile only (ACPA-21), so a test cannot
/// name an embedding model in `config.yaml`. Each test resolves a profile
/// definition through a live router, and embeds text through the resident
/// handle of the `embedding` slot. The `standard`
/// and `flash` slots name two small models, so the run does not load the 27B
/// model of the shipped profile. The first run needs the network, and the
/// suite runs one test at a time because each loads models into the GPU and
/// the Neural Engine.
@Suite(.serialized)
struct EmbeddingModelTests {
  // MARK: - Constants

  /// The small model of the `standard` slot.
  private static let standardModel = "mlx-community/Qwen3-1.7B-4bit"

  /// The small model of the `flash` slot. A profile must name two different
  /// models for these two slots.
  private static let flashModel = "mlx-community/Qwen3-0.6B-4bit"

  /// The Core ML model of the shipped default.
  private static let aneModel = "erjigit17/embeddinggemma-300m-ane-coreml"

  /// The MLX embedding model the shipped default was before.
  private static let mlxModel = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

  /// Two texts about one subject, and one about another.
  private static let texts = [
    "A cat sat on the warm mat by the window.",
    "A kitten rested on a cosy rug near the glass.",
    "The quarterly tax filing is due at the end of the month.",
  ]

  // MARK: - Helpers

  /// Resolves a profile whose `embedding` slot is `embedding` with live
  /// models, and embeds ``texts``.
  ///
  /// - Parameter embedding: The model of the `embedding` slot.
  /// - Returns: One vector for each text.
  private static func embed(with embedding: String) async throws -> [[Float]] {
    _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
    let definition = ProfileDefinition(
      name: "EmbeddingModelTests", description: "Two small models and one embedding model.",
      standard: [ModelRef(standardModel)], flash: [ModelRef(flashModel)],
      embedding: [ModelRef(embedding)])
    let router = Router(
      recordingsDir: makeResolvedDirectory(label: "EmbeddingModelTests-recordings"),
      loader: LiveModelLoader(),
      samplingMode: .greedy)
    let resident = try await router.resolve(profile: definition, reporting: ResolutionProgress())
    return try await resident.embedding.embed(texts: texts)
  }

  /// The cosine similarity of two vectors.
  private static func cosine(_ left: [Float], _ right: [Float]) -> Float {
    let dot = zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
    let norm = { (vector: [Float]) in vector.reduce(0) { $0 + $1 * $1 }.squareRoot() }
    return dot / (norm(left) * norm(right))
  }

  /// Checks the shape and the meaning of the vectors of ``texts``.
  ///
  /// - Parameters:
  ///   - vectors: One vector for each text.
  ///   - dimension: The length every vector must have.
  private static func expectUseful(_ vectors: [[Float]], dimension: Int) {
    #expect(vectors.count == texts.count)
    #expect(vectors.allSatisfy { $0.count == dimension })
    #expect(vectors.allSatisfy { $0.allSatisfy(\.isFinite) && $0.contains { $0 != 0 } })
    guard vectors.count == texts.count else { return }
    let related = cosine(vectors[0], vectors[1])
    let unrelated = cosine(vectors[0], vectors[2])
    #expect(related > unrelated, "related \(related) must beat unrelated \(unrelated)")
  }

  // MARK: - The tests

  /// The embedding model of the default profile is the Core ML model, and
  /// it embeds.
  @Test func theShippedDefaultCoreMLModelLoadsAndEmbeds() async throws {
    #expect(ModelProfiles.named(ModelProfiles.defaultName)?.embedding.map(\.stringValue) == [Self.aneModel])

    let vectors = try await Self.embed(with: Self.aneModel)

    Self.expectUseful(vectors, dimension: 768)
  }

  /// A profile that names the MLX Qwen embedding model loads it and embeds.
  @Test func anMLXQwenEmbeddingModelLoadsAndEmbeds() async throws {
    let vectors = try await Self.embed(with: Self.mlxModel)

    Self.expectUseful(vectors, dimension: 1024)
  }
}

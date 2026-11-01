import Foundation
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import FoundationModelsRouterTestSupport
import Testing

/// Proves that a configuration file loads and uses a REAL embedding model of
/// each format: the Core ML model on the Apple Neural Engine (the shipped
/// default) and the MLX Qwen embedding model.
///
/// Each test writes a user-layer `config.yaml`, loads it through the
/// `ConfigurationLoader`, resolves the profile through a live router, and embeds
/// text through the resident handle of the `embedding` slot. The `standard`
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

    /// Loads `embeddingYAML` as the `embedding` slot of a profile, resolves the
    /// profile with live models, and embeds ``texts``.
    ///
    /// - Parameter embeddingYAML: The value of the `embedding:` key.
    /// - Returns: The configuration that loaded, and one vector for each text.
    private static func embed(embeddingYAML: String) async throws -> (ProfileConfiguration, [[Float]]) {
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        let userDirectory = makeResolvedDirectory(label: "EmbeddingModelTests-user")
        let yaml = """
            profile:
              standard: ["\(standardModel)"]
              flash: ["\(flashModel)"]
              embedding: \(embeddingYAML)
            """
        try yaml.write(
            to: userDirectory.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        let home = AgentHomeFixture.make(label: "EmbeddingModelTests", synced: userDirectory)
        let name = try DotfolderName(AgentClientHarness.dotfolderName)
        let profile = try ConfigurationLoader(
            name: name, workingDirectory: userDirectory, home: home, environment: [:]
        ).load().configuration.profile
        let router = Router(
            recordingsDir: makeResolvedDirectory(label: "EmbeddingModelTests-recordings"),
            loader: LiveModelLoader(),
            samplingMode: .greedy)
        let resident = try await profile.resolveResident(
            fallbackName: name, router: router, reporting: ResolutionProgress())
        let vectors = try await resident.embedding.embed(texts: texts)
        return (profile, vectors)
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

    /// The shipped default, with no `embedding` key in the file, is the Core ML
    /// model, and it embeds.
    @Test func theShippedDefaultCoreMLModelLoadsAndEmbeds() async throws {
        #expect(ProfileConfiguration.defaultEmbedding.map(\.stringValue) == [Self.aneModel])

        let (_, vectors) = try await Self.embed(embeddingYAML: "[\"\(Self.aneModel)\"]")

        Self.expectUseful(vectors, dimension: 768)
    }

    /// A configuration file that names the MLX Qwen embedding model loads it
    /// and embeds.
    @Test func aConfiguredMLXQwenEmbeddingModelLoadsAndEmbeds() async throws {
        let (profile, vectors) = try await Self.embed(embeddingYAML: "[\"\(Self.mlxModel)\"]")

        #expect(profile.embedding.map(\.stringValue) == [Self.mlxModel])
        Self.expectUseful(vectors, dimension: 1024)
    }
}

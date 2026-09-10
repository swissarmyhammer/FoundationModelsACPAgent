import FoundationModelsRouter
import Synchronization

// MARK: - The recording embedder seam
//
// `ToolCatalog.sessionSurface(context:)` hands the profile's embedding
// handle to the Multitool mount, and the Multitool keeps that handle
// internal. A test reads the hand-over through behavior instead: the
// mounted `searchTools` embeds every catalog block at its first search and
// the query at each search, so the texts the profile's embedder received
// are the proof. This container plugs into the same `StubModelLoader` seam
// `ScriptedModel.swift` uses for the LLM slots:
//
//   StubModelLoader (ModelLoader) -> RecordingEmbeddingContainer
//     -> the wrapped LoadedEmbeddingContainer

/// An embedding container that records every batch of texts it is asked to
/// embed, and answers each batch through the container it wraps.
///
/// A class, so the test that injects one and the profile that resolves it
/// share one recording. The batches are guarded by a `Mutex`, so the
/// `Sendable` conformance stays compiler-checked.
public final class RecordingEmbeddingContainer: LoadedEmbeddingContainer {
    /// The container every embed is answered through.
    private let wrapped: any LoadedEmbeddingContainer

    /// Every batch of texts received, in call order.
    private let received = Mutex<[[String]]>([])

    /// Creates a recording container over `wrapped`.
    ///
    /// - Parameter wrapped: The container that answers each embed.
    public init(wrapping wrapped: any LoadedEmbeddingContainer) {
        self.wrapped = wrapped
    }

    public var dimension: Int { wrapped.dimension }

    /// Every batch of texts this container was asked to embed, in call
    /// order: one element per `embed(texts:)` call.
    public var batches: [[String]] {
        received.withLock { $0 }
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        received.withLock { $0.append(texts) }
        return try await wrapped.embed(texts: texts)
    }
}

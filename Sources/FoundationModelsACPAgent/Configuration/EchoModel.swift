import Foundation
import FoundationModels
import FoundationModelsRouter

// MARK: - The deterministic model path (cli-plan.md §9)
//
// A router over models that download nothing, fetch no metadata, and
// generate nothing but the prompt itself. Two callers build on it:
//
// - The test support's stub agent and stub profile factories, so every
//   unit suite resolves a profile without MLX, without a download, and
//   without the network (plan.md §20.1).
// - The agent CLI's `ACP_AGENT_STUB_MODEL=1` composition, so a spawned
//   `acp-agent` answers deterministically across a real process boundary.
//   The scripted model of the test support is in-process only, and a
//   real small model's sampling is not reproducible, so the product
//   carries this path itself.
//
// The shape follows Multitool's own `StubRouterFixtures.swift`:
//
//   StubModelLoader (ModelLoader) -> EchoLLMContainer (LoadedLLMContainer)
//     -> EchoSessionBackend (LanguageModelSessionBackend)
//
// **The container writes all four session factories on purpose.** The public
// default of `makeSession(instructions:tools:)` DROPS `tools` and forwards to
// `makeSession(instructions:)`. A container that writes only the two required
// factories gets a backend with an empty tool list, and a fixture over it
// passes while measuring nothing.

/// A session backend that answers each prompt with the prompt itself.
///
/// The echo answer keeps the backend honest for a call without a model
/// and without a download: the text is real, and it is the same on every
/// run.
///
/// A class, not a struct, because `LanguageModelSessionBackend` requires
/// `AnyObject`. The type holds no state, so its `Sendable` conformance is
/// compiler-checked — no `@unchecked` assertion is needed.
public final class EchoSessionBackend: LanguageModelSessionBackend {
    /// Creates a backend that echoes every prompt.
    public init() {}

    public func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        prompt
    }

    public func respond(
        to prompt: String, following grammar: Grammar, maxTokens: Int?
    ) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    public func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(prompt)
            continuation.finish()
        }
    }

    public func makeFork() -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }

    public func transcriptEntries() -> [Transcript.Entry] {
        []
    }

    public func usageTokenCounts() -> (input: Int, output: Int)? {
        (1, 1)
    }
}

/// A resident model that hands every session an ``EchoSessionBackend``.
///
/// All four factories are written out. See the file comment: the public
/// default of `makeSession(instructions:tools:)` drops `tools`.
public struct EchoLLMContainer: LoadedLLMContainer {
    /// Creates a container that vends ``EchoSessionBackend``.
    public init() {}

    public func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }

    public func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }

    public func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }

    public func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }
}

/// An embedding model that answers a constant vector.
///
/// Public, like ``EchoLLMContainer``, so the test support wraps it: a
/// recording container forwards each embed here and keeps the texts.
public struct StubEmbeddingContainer: LoadedEmbeddingContainer {
    /// Creates an embedding container that answers a constant vector.
    public init() {}

    /// The one dimension count every stub vector has.
    private static let stubDimension = 8

    /// The one value every component of every stub vector has.
    private static let stubComponent: Float = 0.5

    public let dimension = StubEmbeddingContainer.stubDimension

    public func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { _ in
            [Float](repeating: Self.stubComponent, count: Self.stubDimension)
        }
    }
}

/// A loader that downloads nothing and loads the stub containers.
public struct StubModelLoader: ModelLoader {
    /// The one-byte progress a stub load reports, so a progress consumer
    /// observes a complete download.
    private static let completeProgress = DownloadProgress(bytesDownloaded: 1, bytesTotal: 1)

    /// The factory for the LLM container each load vends, given the slot
    /// being loaded. The default vends ``EchoLLMContainer`` for every
    /// slot; a recording test injects a container whose backend
    /// accumulates transcript entries, and a config-options test injects
    /// per-slot containers so a turn's text names the slot that
    /// generated it.
    public var makeLLMContainer: @Sendable (ModelSlot) -> any LoadedLLMContainer

    /// The factory for the embedding container each embedder load vends,
    /// given the slot being loaded. The default vends
    /// ``StubEmbeddingContainer`` for every slot; a discovery test injects
    /// a recording container, so it reads which texts the mounted
    /// `searchTools` gave the profile's embedder.
    public var makeEmbeddingContainer: @Sendable (ModelSlot) -> any LoadedEmbeddingContainer

    /// Creates a loader over ``makeLLMContainer`` and
    /// ``makeEmbeddingContainer``.
    ///
    /// - Parameters:
    ///   - makeLLMContainer: The container factory each LLM load vends
    ///     through. The default vends ``EchoLLMContainer`` for every slot.
    ///   - makeEmbeddingContainer: The container factory each embedder
    ///     load vends through. The default vends ``StubEmbeddingContainer``
    ///     for every slot.
    public init(
        makeLLMContainer: @escaping @Sendable (ModelSlot) -> any LoadedLLMContainer = { _ in
            EchoLLMContainer()
        },
        makeEmbeddingContainer: @escaping @Sendable (ModelSlot) -> any LoadedEmbeddingContainer = { _ in
            StubEmbeddingContainer()
        }
    ) {
        self.makeLLMContainer = makeLLMContainer
        self.makeEmbeddingContainer = makeEmbeddingContainer
    }

    public func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        reporting(Self.completeProgress)
        return makeLLMContainer(slot)
    }

    public func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        reporting(Self.completeProgress)
        return makeEmbeddingContainer(slot)
    }

    public func preload(container: any LoadedModelContainer) async throws {}
}

/// A machine large enough that slot fitting never becomes a variable.
struct StubMachine: MachineProbe {
    /// Creates a probe of the oversized stub machine.
    init() {}

    let chip = "Apple Stub"
    let totalRAM: Int64 = 64 << 30
    let recommendedMaxWorkingSetSize: Int64 = 48 << 30
}

/// Metadata for a model small enough to fit ``StubMachine`` trivially.
///
/// The numbers match Multitool's stub fixture, which measured them as
/// sufficient for the sizing pass.
struct StubMetadata: MetadataSource {
    /// Creates a metadata source of one tiny model.
    init() {}

    func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
        RawRepoMetadata(
            configJSON: Data(
                """
                {"num_hidden_layers":2,"num_attention_heads":8,\
                "num_key_value_heads":2,"head_dim":16,"hidden_size":128}
                """.utf8),
            treeJSON: Data(
                """
                [{"type":"file","path":"model.safetensors","size":10000000}]
                """.utf8))
    }
}

/// The router factory of the deterministic model path.
public enum EchoModel {
    /// Makes a router over the stub components: a large machine, tiny
    /// metadata, and a loader that downloads nothing. Every profile it
    /// resolves is resident at once, and every session it opens answers
    /// through the loader's containers — ``EchoLLMContainer`` by default.
    ///
    /// Each call also makes its own `ModelPool`, and that is what keeps the
    /// answer the caller's own. A pool holds one resident container for each
    /// model identity, and the FIRST loader to reach a key wins it: a later
    /// router that names the same key gets the container the first loader
    /// made, whatever its own loader would have made. Every stub router names
    /// the same tiny model, so one shared pool would give every router the
    /// container of whichever router ran first, and a scripted caller would
    /// then read another caller's script. A pool of its own gives each router
    /// the containers of its own loader.
    ///
    /// - Parameters:
    ///   - cacheDirectory: Where the router caches. A fresh temporary
    ///     directory per call keeps runs of one suite apart.
    ///   - recordingsDirectory: The durable transcripts root, or `nil` (the
    ///     default) to record nothing.
    ///   - loader: The loader the router loads through.
    /// - Returns: The router to resolve against.
    public static func makeRouter(
        cacheDirectory: URL,
        recordingsDirectory: URL? = nil,
        loader: any ModelLoader = StubModelLoader()
    ) -> Router {
        Router(
            cacheDir: cacheDirectory,
            recordingsDir: recordingsDirectory,
            probe: StubMachine(),
            metadataSource: StubMetadata(),
            loader: loader,
            pool: ModelPool()
        )
    }
}

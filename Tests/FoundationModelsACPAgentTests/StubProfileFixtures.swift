import Foundation
import FoundationModels
import FoundationModelsACPAgent
import FoundationModelsRouter

// MARK: - A resolved profile over stub models
//
// `ToolCatalog` needs a resolved `LanguageModelProfile`: the librarian slot
// of `makeSessionTools(librarian:)` and the skills selection tier both come
// from it. Router makes no profile publicly — `LanguageModelProfile.init` is
// package-internal — so these fixtures stand up a router over models that
// download nothing and generate nothing, in the pattern of Multitool's own
// `StubRouterFixtures.swift`:
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
/// The catalog tests construct tools and read surfaces; no test generates
/// text. The echo answer keeps the backend honest for an accidental call
/// without a model and without a download.
///
/// A class, not a struct, because `LanguageModelSessionBackend` requires
/// `AnyObject`. The type holds no state, so its `Sendable` conformance is
/// compiler-checked — no `@unchecked` assertion is needed.
final class EchoSessionBackend: LanguageModelSessionBackend {
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        prompt
    }

    func respond(
        to prompt: String, following grammar: Grammar, maxTokens: Int?
    ) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(prompt)
            continuation.finish()
        }
    }

    func makeFork() -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }

    func transcriptEntries() -> [Transcript.Entry] {
        []
    }

    func usageTokenCounts() -> (input: Int, output: Int)? {
        (1, 1)
    }
}

/// A resident model that hands every session an ``EchoSessionBackend``.
///
/// All four factories are written out. See the file comment: the public
/// default of `makeSession(instructions:tools:)` drops `tools`.
struct EchoLLMContainer: LoadedLLMContainer {
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }

    func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }

    func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        EchoSessionBackend()
    }
}

/// An embedding model that answers a constant vector.
struct StubEmbeddingContainer: LoadedEmbeddingContainer {
    /// The one dimension count every stub vector has.
    private static let stubDimension = 8

    /// The one value every component of every stub vector has.
    private static let stubComponent: Float = 0.5

    let dimension = StubEmbeddingContainer.stubDimension

    func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { _ in
            [Float](repeating: Self.stubComponent, count: Self.stubDimension)
        }
    }
}

/// A loader that downloads nothing and loads the stub containers.
struct StubModelLoader: ModelLoader {
    /// The one-byte progress a stub load reports, so a progress consumer
    /// observes a complete download.
    private static let completeProgress = DownloadProgress(bytesDownloaded: 1, bytesTotal: 1)

    /// The factory for the LLM container each load vends. The default vends
    /// ``EchoLLMContainer``; a recording test injects a container whose
    /// backend accumulates transcript entries instead.
    var makeLLMContainer: @Sendable () -> any LoadedLLMContainer = { EchoLLMContainer() }

    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        reporting(Self.completeProgress)
        return makeLLMContainer()
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        reporting(Self.completeProgress)
        return StubEmbeddingContainer()
    }

    func preload(container: any LoadedModelContainer) async throws {}
}

/// A machine large enough that slot fitting never becomes a variable.
struct StubMachine: MachineProbe {
    let chip = "Apple Stub"
    let totalRAM: Int64 = 64 << 30
    let recommendedMaxWorkingSetSize: Int64 = 48 << 30
}

/// Metadata for a model small enough to fit ``StubMachine`` trivially.
///
/// The numbers match Multitool's stub fixture, which measured them as
/// sufficient for the sizing pass.
struct StubMetadata: MetadataSource {
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

/// Makes a router over the stub components: a large machine, tiny
/// metadata, and a loader that downloads nothing.
///
/// - Parameters:
///   - cacheDirectory: Where the router caches. A fresh temporary
///     directory per call keeps runs of one suite apart.
///   - recordingsDirectory: The durable transcripts root, or `nil` (the
///     default) to record nothing.
///   - loader: The loader the router loads through.
/// - Returns: The router to resolve against.
func makeStubRouter(
    cacheDirectory: URL,
    recordingsDirectory: URL? = nil,
    loader: any ModelLoader = StubModelLoader()
) -> Router {
    Router(
        cacheDir: cacheDirectory,
        recordingsDir: recordingsDirectory,
        probe: StubMachine(),
        metadataSource: StubMetadata(),
        loader: loader
    )
}

/// Makes an agent over a stub router, so the construction-time profile
/// resolution downloads nothing and touches no network. The one test
/// agent factory: every suite constructs through it.
///
/// - Parameters:
///   - name: The bare dotfolder name to construct the agent with.
///   - cacheDirectory: Where the router caches. A fresh temporary
///     directory per call keeps runs of one suite apart.
///   - loader: The loader the router loads through.
/// - Returns: The constructed agent.
/// - Throws: `DotfolderNameError` when `name` is refused, or
///   `ProfileResolutionError` when the stub resolution fails.
func makeStubAgent(
    name: String,
    cacheDirectory: URL,
    loader: any ModelLoader = StubModelLoader()
) async throws -> RoutedACPAgent {
    let router = makeStubRouter(cacheDirectory: cacheDirectory, loader: loader)
    return try await RoutedACPAgent(name: DotfolderName(name), router: router)
}

/// Resolves a profile over the stub models, resident and generation-free.
///
/// - Parameters:
///   - cacheDirectory: Where the router caches. A fresh temporary
///     directory per call keeps runs of one suite apart.
///   - recordingsDirectory: The durable transcripts root, or `nil` (the
///     default) to record nothing.
///   - loader: The loader the router loads through. The default vends the
///     echo containers; a recording test injects a transcript-accumulating
///     container through ``StubModelLoader/makeLLMContainer``.
/// - Returns: The resolved profile. It retains its router, so the caller
///   holds the profile alone.
/// - Throws: Whatever resolving the profile throws.
func makeStubProfile(
    cacheDirectory: URL,
    recordingsDirectory: URL? = nil,
    loader: StubModelLoader = StubModelLoader()
) async throws -> LanguageModelProfile {
    let router = makeStubRouter(
        cacheDirectory: cacheDirectory,
        recordingsDirectory: recordingsDirectory,
        loader: loader
    )
    return try await router.resolve(
        profile: ProfileDefinition(
            name: "stub",
            description: "the stub profile these fixtures run on",
            standard: ["stub/standard"],
            flash: ["stub/flash"],
            embedding: ["stub/embedding"]
        ),
        reporting: ResolutionProgress()
    )
}

import Foundation
import FoundationModelsACPAgent
import FoundationModelsRouter
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// The composition every subcommand shares (cli-plan.md §5.10, plan.md
/// §20.2): the dotfolder name, the configuration stack, the router over
/// a model loader, and the composed agent. `run` and `acp` both build
/// their agent here, so the two modes cannot drift apart.
///
/// The composition is the whole lesson. There is no configuration
/// wizardry: the dotfolder name is the one choice a frontend makes, and
/// everything else derives.
///
/// Where a frontend appends its own tools (plan.md §11.1): `ToolCatalog`
/// is the one place this package composes the per-session tool surface.
/// A capability behind the code-mode surface is one
/// `builder.withCapability(myCapability)` call in
/// `ToolCatalog.makeRegistry(context:)`; a stand-alone tool is one plain
/// `FoundationModels.Tool` appended in `ToolCatalog.sessionSurface(context:)`,
/// the way the `skills` tool is.
enum AgentComposition {
    /// The dotfolder name — the frontend's one choice.
    ///
    /// The name roots the configuration stack — `$XDG_CONFIG_HOME/acp-agent/`
    /// for the user layer, `<cwd>/.acp-agent/` for the project layer — and
    /// the transcript directory, and it is the fallback for the profile's
    /// name (plan.md §2.1). It never goes on the wire: `initialize` reports
    /// the package identity instead (§5).
    static let dotfolderName = "acp-agent"

    /// The environment variable that selects ``ModelSource/stub`` in place
    /// of the live loader. Set it to ``stubModelEnabledValue``.
    ///
    /// It exists because a spawned-binary test has no other deterministic
    /// model: the scripted model of the test support is in-process only,
    /// and the one cross-process control before this was a real small
    /// model whose sampling is not reproducible.
    static let stubModelVariable = "ACP_AGENT_STUB_MODEL"

    /// The value of ``stubModelVariable`` that selects the stub model. Any
    /// other value, and an absent variable, select the live loader.
    static let stubModelEnabledValue = "1"

    /// Which model path the router resolves the profile through.
    enum ModelSource: Equatable {
        /// `LiveModelLoader` over the Hub downloader and tokenizer macros:
        /// the configured models download on first use and load as
        /// resident weights. Nothing here is scripted or stubbed.
        case live

        /// The library's deterministic `EchoModel` path: every session
        /// answers a prompt with the prompt itself, no metadata is
        /// fetched, no weights download, and nothing loads.
        case stub
    }

    /// The prefix of the throwaway cache directory a stub router writes
    /// its stub metadata under. The real caches directory must never hold
    /// that metadata: it names real model ids, and a later live run would
    /// read the fake sizes back.
    private static let stubCacheDirectoryPrefix = "acp-agent-stub-cache-"

    /// What one composition gives: the agent, and the model path it was
    /// built over, so a caller can say which one it got.
    struct Composed {
        /// The composed agent, with its profile resolved.
        let agent: RoutedACPAgent

        /// The model path ``agent`` resolves through.
        let modelSource: ModelSource
    }

    /// The process working directory, as a directory URL. It roots the
    /// stack of the `acp` mode, and it is the `run` default (§5.4).
    static var processWorkingDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// Reads ``stubModelVariable`` out of `environment`.
    ///
    /// - Parameter environment: The environment to read.
    /// - Returns: ``ModelSource/stub`` when the variable holds
    ///   ``stubModelEnabledValue``; ``ModelSource/live`` otherwise.
    static func modelSource(environment: [String: String]) -> ModelSource {
        environment[stubModelVariable] == stubModelEnabledValue ? .stub : .live
    }

    /// Composes the agent: the configuration of `workingDirectory`'s
    /// stack, a router over the model path `environment` selects, and the
    /// `RoutedACPAgent` construction that resolves the profile.
    ///
    /// The layered `config.yaml` of `workingDirectory` selects the profile
    /// the agent resolves at start (plan.md §2.2). With no file in any
    /// layer the in-code default applies. Each session later loads its own
    /// stack again, keyed by the session's `cwd`.
    ///
    /// - Parameters:
    ///   - workingDirectory: The directory whose dotfolder stack the
    ///     start-up configuration loads from.
    ///   - environment: The environment the stack reads `XDG_CONFIG_HOME`
    ///     from, and ``modelSource(environment:)`` reads the model switch
    ///     from.
    /// - Returns: The composed agent, and the model path it was built over.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused,
    ///   the configuration load errors, the stub cache directory cannot be
    ///   created, or `ProfileResolutionError` when the profile does not
    ///   resolve. Each is fatal before the wire opens.
    static func compose(
        workingDirectory: URL, environment: [String: String]
    ) async throws -> Composed {
        let name = try DotfolderName(dotfolderName)
        let configuration = try ConfigurationLoader(
            name: name, workingDirectory: workingDirectory, environment: environment
        ).load().configuration
        let modelSource = modelSource(environment: environment)
        let agent = try await RoutedACPAgent(
            name: name,
            router: try makeRouter(for: modelSource),
            configuration: configuration,
            environment: environment)
        return Composed(agent: agent, modelSource: modelSource)
    }

    /// Makes the router of one model path.
    ///
    /// - Parameter modelSource: The model path to build the router over.
    /// - Returns: A router over `LiveModelLoader` for ``ModelSource/live``,
    ///   or the library's `EchoModel` router — stub machine, stub
    ///   metadata, echo loader — for ``ModelSource/stub``.
    /// - Throws: The directory-creation error of the stub cache.
    private static func makeRouter(for modelSource: ModelSource) throws -> Router {
        switch modelSource {
        case .live:
            Router(
                loader: LiveModelLoader(
                    downloader: #hubDownloader(),
                    tokenizerLoader: #huggingFaceTokenizerLoader()))
        case .stub:
            EchoModel.makeRouter(cacheDirectory: try makeStubCacheDirectory())
        }
    }

    /// Makes a fresh throwaway directory for a stub router's cache — see
    /// ``stubCacheDirectoryPrefix``.
    ///
    /// - Returns: The created directory, under the temporary directory.
    /// - Throws: The directory-creation error.
    private static func makeStubCacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(stubCacheDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

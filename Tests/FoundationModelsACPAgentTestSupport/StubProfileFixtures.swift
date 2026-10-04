import Foundation
import FoundationModelsACPAgent
import FoundationModelsRouter
import Tracing

// MARK: - A resolved profile over stub models
//
// `ToolCatalog` needs a resolved `LanguageModelProfile`: the librarian slot
// of the `searchTools` selection tier and the skills selection tier both come
// from it. Router makes no profile publicly — `LanguageModelProfile.init` is
// package-internal — so these factories stand up an agent, or a profile,
// over the library's own deterministic model path, `EchoModel`: a router
// over models that download nothing and generate nothing but the prompt.
// The library carries that path because the agent CLI's
// `ACP_AGENT_STUB_MODEL=1` composition builds on it too (cli-plan.md §9);
// `ScriptedModel.swift` plugs its scripted containers into the same
// `StubModelLoader` seam.

/// Makes an agent over a stub router, so the construction-time profile
/// resolution downloads nothing and touches no network. The one test
/// agent factory: every suite constructs through it.
///
/// The agent's environment does not come from the process, so a session
/// never reads the real process environment; a suite that composes
/// sessions injects `userDirectory` so nothing touches the real home
/// directory either. The environment holds one key only: the defaults
/// layer of ``StubAgentDefaultsLayer``, which turns the code context off
/// for each session of the agent.
///
/// - Parameters:
///   - name: The bare dotfolder name to construct the agent with.
///   - cacheDirectory: Where the router caches. A fresh temporary
///     directory per call keeps runs of one suite apart.
///   - recordingsDirectory: The durable transcripts root, or `nil` (the
///     default) to record nothing — a session-composition suite passes a
///     value so `makeSession` writes the session directory to disk.
///   - userDirectory: The injected user layer root, or `nil` when the
///     suite composes no session.
///   - loader: The loader the router loads through.
///   - tracer: The tracer of each Router session, or `nil` (the default) to
///     read `InstrumentationSystem.tracer` at call time. A suite that
///     captures the Router spans gives the tracer of its capture — see
///     ``EchoModel/makeRouter(cacheDirectory:recordingsDirectory:loader:tracer:)``.
/// - Returns: The constructed agent.
/// - Throws: `DotfolderNameError` when `name` is refused,
///   `ProfileResolutionError` when the stub resolution fails, or the
///   write error of the defaults layer.
public func makeStubAgent(
    name: String,
    cacheDirectory: URL,
    recordingsDirectory: URL? = nil,
    userDirectory: URL? = nil,
    loader: any ModelLoader = StubModelLoader(),
    tracer: (any Tracer)? = nil
) async throws -> RoutedACPAgent {
    let router = EchoModel.makeRouter(
        cacheDirectory: cacheDirectory,
        recordingsDirectory: recordingsDirectory,
        loader: loader,
        tracer: tracer)
    return try await RoutedACPAgent(
        name: DotfolderName(name),
        router: router,
        userDirectory: userDirectory,
        environment: StubAgentDefaultsLayer.makeEnvironment(name: name))
}

// MARK: - The defaults layer of a stub agent

/// The defaults layer that ``makeStubAgent(name:cacheDirectory:recordingsDirectory:userDirectory:loader:tracer:)``
/// gives each agent: the lowest layer of the configuration stack, below the
/// user layer and the project layer.
///
/// Its `config.yaml` turns the code context off. A code context starts an
/// FSEvents stream for its workspace, and fseventsd registers the streams
/// of the whole machine one at a time. On a loaded machine one registration
/// takes 0.1 s to 0.3 s, and ten registrations at the same time take more
/// than 9 s. Thus in a parallel run each fixture waited for the code
/// contexts of all the other fixtures, and a test that made two or more
/// fixtures waited two or more times (task `^vjaka1g`). No unit test reads
/// the code context through an agent: `ToolCatalogTests` tests it through
/// `ToolCatalog`. A test that needs it through an agent turns it on in its
/// project layer, which is higher than this layer.
///
/// A suite that composes the CLI agent through `AgentComposition` gives the
/// same layer to the environment of that composition.
public enum StubAgentDefaultsLayer {
    /// The `config.yaml` of the layer.
    static let configYAML = "tools:\n  codeContext: false\n"

    /// The suffix of the environment key that `DotfolderStack` reads the
    /// defaults layer root from: `<NAME>_DEFAULTS_DIR`, with the dotfolder
    /// name in upper case.
    static let environmentKeySuffix = "_DEFAULTS_DIR"

    /// Writes the layer into a fresh directory, and returns `base` with the
    /// key that names that directory as the defaults layer root of `name`.
    ///
    /// - Parameters:
    ///   - name: The bare dotfolder name of the agent.
    ///   - base: The environment the agent reads otherwise. Empty by default.
    /// - Returns: `base`, with the defaults layer key added.
    /// - Throws: The directory-creation or write error.
    public static func makeEnvironment(
        name: String, base: [String: String] = [:]
    ) throws -> [String: String] {
        let root = makeResolvedDirectory(label: "StubAgentDefaultsLayer")
        try ConfigFileFixture.write(configYAML, in: root)
        var environment = base
        environment[name.uppercased() + environmentKeySuffix] = root.path
        return environment
    }
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
public func makeStubProfile(
    cacheDirectory: URL,
    recordingsDirectory: URL? = nil,
    loader: StubModelLoader = StubModelLoader()
) async throws -> LanguageModelProfile {
    let router = EchoModel.makeRouter(
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

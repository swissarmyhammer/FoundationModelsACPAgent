import Foundation
import FoundationModelsACPAgent
import FoundationModelsRouter

// MARK: - A resolved profile over stub models
//
// `ToolCatalog` needs a resolved `LanguageModelProfile`: the librarian slot
// of `makeSessionTools(librarian:)` and the skills selection tier both come
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
/// The agent's environment is empty on purpose, so a session never reads
/// the real process environment; a suite that composes sessions injects
/// `userDirectory` so nothing touches the real home directory either.
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
/// - Returns: The constructed agent.
/// - Throws: `DotfolderNameError` when `name` is refused, or
///   `ProfileResolutionError` when the stub resolution fails.
public func makeStubAgent(
    name: String,
    cacheDirectory: URL,
    recordingsDirectory: URL? = nil,
    userDirectory: URL? = nil,
    loader: any ModelLoader = StubModelLoader()
) async throws -> RoutedACPAgent {
    let router = EchoModel.makeRouter(
        cacheDirectory: cacheDirectory,
        recordingsDirectory: recordingsDirectory,
        loader: loader)
    return try await RoutedACPAgent(
        name: DotfolderName(name),
        router: router,
        userDirectory: userDirectory,
        environment: [:])
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

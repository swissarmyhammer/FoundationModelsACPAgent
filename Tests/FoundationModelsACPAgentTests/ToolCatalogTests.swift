import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsCodeContext
import FoundationModelsMultitool
import FoundationModelsRouter
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

/// The composition matrix of `ToolCatalog` (plan.md §11.1–§11.4): the
/// session tools a default context mounts, the enable and disable codec,
/// the root-set confinement of the files verbs, and the watched skills
/// registry.
///
/// The per-verb argument and output structs of the capability modules are
/// internal upstream, so composition is asserted through the built
/// `APISurface.entries` paths, and a verb is exercised through the public
/// `ToolInvoker.invoke(_:content:)` door with its wire JSON.
@Suite struct ToolCatalogTests {
    /// The mount order a default context gives the model: the two
    /// Multitool session tools, then the appended standalone skills tool.
    private static let defaultToolNames = ["searchTools", "runCode", "skills"]

    /// The mount order with the skills section disabled: the Multitool
    /// session tools alone.
    private static let multitoolOnlyNames = ["searchTools", "runCode"]

    /// The surface path of the files read verb.
    private static let readVerbPath = FilesVerbSupport.readVerbPath

    /// The surface path of the shell execute verb.
    private static let executeVerbPath = "shell.execute"

    /// The noun the files capability owns on the surface.
    private static let filesNoun = "files"

    /// The noun the shell capability owns on the surface.
    private static let shellNoun = "shell"

    /// The noun the web capability owns on the surface.
    private static let webNoun = "web"

    /// The surface path of the web search verb.
    private static let webSearchPath = "web.search"

    /// The surface path of the web fetch verb.
    private static let webFetchPath = "web.fetch"

    /// The branch of the one commit of the temporary git repository.
    private static let repositoryBranch = "catalog-branch"

    /// The task the embedder proof gives the mounted `searchTools`.
    private static let embedderTask = "read one text file from the workspace"

    /// The selection the scripted flash slot answers, in the shape
    /// `SelectionTier` decodes, so the search completes.
    private static let flashSelectionJSON = #"{"ids":["\#(readVerbPath)"]}"#

    // MARK: Harness

    /// Makes a fresh throwaway directory and returns its URL.
    ///
    /// - Parameter label: The suffix that names the directory's role.
    /// - Returns: The created directory.
    /// - Throws: Whatever directory creation throws.
    private static func makeTemporaryDirectory(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolCatalogTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Makes a catalog context over a fresh working directory and a stub
    /// profile.
    ///
    /// - Parameters:
    ///   - additionalRoots: The session's additional roots, in order.
    ///   - loader: The loader the stub profile resolves through. The
    ///     default vends the echo containers.
    ///   - environment: The process environment the web capability reads
    ///     its API keys from. The default is empty, thus no test reads a
    ///     key of the machine that runs it.
    ///   - keepsCodeContext: `true` keeps the default `codeContext:`
    ///     section. Each registry build then starts a `CodeContext`, and
    ///     the test must call `codeContextStop` before it ends. The
    ///     default `false` turns the section off, thus a test that does
    ///     not test the code context starts none.
    ///   - configure: The mutation that shapes the configuration under
    ///     test. It runs after the `codeContext:` section is set. The
    ///     default keeps every other section at its default.
    /// - Returns: The context under test.
    /// - Throws: Whatever the directory creation or the profile resolve
    ///   throws.
    private static func makeContext(
        additionalRoots: [URL] = [],
        loader: StubModelLoader = StubModelLoader(),
        environment: [String: String] = [:],
        keepsCodeContext: Bool = false,
        configure: (inout AgentConfiguration) -> Void = { _ in }
    ) async throws -> CatalogContext {
        var configuration = AgentConfiguration()
        if !keepsCodeContext {
            configuration.tools.codeContext = .disabled
        }
        configure(&configuration)
        return CatalogContext(
            workingDirectory: try makeTemporaryDirectory(label: "work"),
            additionalRoots: additionalRoots,
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: try makeTemporaryDirectory(label: "cache"),
                loader: loader),
            environment: environment)
    }

    /// Invokes `tools.files.read` on `path` and decodes the wire result
    /// through the shared ``FilesVerbSupport`` helper.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose read verb to invoke.
    ///   - path: The path argument to read.
    /// - Returns: The decoded wire result.
    /// - Throws: Whatever the invocation or the decode throws.
    private static func invokeRead(
        in registry: MultiTool.Registry, path: String
    ) async throws -> FilesVerbSupport.ReadVerbResult {
        try await FilesVerbSupport.invokeRead(
            try #require(registry.tools[readVerbPath]), path: path)
    }

    // MARK: The session tools

    @Test func aDefaultContextMountsTheFourSessionTools() async throws {
        let context = try await Self.makeContext(keepsCodeContext: true)

        let surface = try await ToolCatalog.sessionSurface(context: context)

        #expect(surface.tools.map(\.name) == Self.defaultToolNames)
        let stop = try #require(surface.codeContextStop)
        await stop()
    }

    @Test func aDisabledSkillsSectionAppendsNoSkillsTool() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.skills = .disabled
        }

        let surface = try await ToolCatalog.sessionSurface(context: context)

        #expect(surface.tools.map(\.name) == Self.multitoolOnlyNames)
    }

    // MARK: The profile embedder

    /// The mount ranks with the profile's embedding handle: the first
    /// `searchTools` call embeds the embedded text of every catalog entry
    /// (`renderEmbeddedText(from:)`) in one batch. With no embedder on the
    /// mount, the profile's embedder receives nothing and the search is
    /// keyword-only.
    ///
    /// The catalog batch is the only batch. The mount also gives a
    /// librarian, thus the searcher runs in `.auto` mode with a selection
    /// tier, and `MetadataSearcher.search(intent:limit:)` sends the query
    /// to that tier. Only the retrieval tier embeds a query, and this
    /// mount does not reach it.
    ///
    /// The `codeContext:` section is off. The code context is a different
    /// consumer of the same embedder: each `CodeContext` embeds one probe
    /// text to learn the vector length, and its index pass runs in the
    /// background. With the section on, those batches would come in at
    /// no known time, between the batches of `searchTools`.
    @Test func theSessionSurfaceHandsTheProfileEmbedderToSearchTools() async throws {
        let embedder = RecordingEmbeddingContainer(wrapping: StubEmbeddingContainer())
        var loader = makeScriptedModelLoader(script: [.textDelta(Self.flashSelectionJSON), .endPass])
        loader.makeEmbeddingContainer = { _ in embedder }
        let context = try await Self.makeContext(loader: loader) { configuration in
            configuration.tools.codeContext = .disabled
        }
        let catalogTexts = try await ToolCatalog.makeRegistry(context: context).registry.surface.entries
            .map { entry in entry.renderEmbeddedText(from: entry.block) }

        let surface = try await ToolCatalog.sessionSurface(context: context)
        let searchTools = try #require(surface.tools.compactMap { $0 as? SearchToolsTool }.first)
        _ = try await searchTools.call(arguments: SearchToolsArguments(task: Self.embedderTask))

        #expect(embedder.batches == [catalogTexts])
    }

    // MARK: The built surface

    @Test func aDefaultRegistrySurfacesTheFilesAndShellNouns() async throws {
        let context = try await Self.makeContext(keepsCodeContext: true)

        let built = try await ToolCatalog.makeRegistry(context: context)

        let paths = built.registry.surface.entries.map(\.path)
        #expect(paths.contains(Self.readVerbPath))
        #expect(paths.contains(Self.executeVerbPath))
        let stop = try #require(built.codeContextStop)
        await stop()
    }

    @Test func aDisabledShellSectionYieldsNoShellNamespace() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.shell = .disabled
        }

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        #expect(!registry.surface.entries.contains { $0.group == Self.shellNoun })
        #expect(registry.surface.entries.contains { $0.path == Self.readVerbPath })
    }

    @Test func aDisabledFilesSectionYieldsNoFilesNamespace() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.files = .disabled
        }

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        #expect(!registry.surface.entries.contains { $0.group == Self.filesNoun })
        #expect(registry.surface.entries.contains { $0.path == Self.executeVerbPath })
    }

    // MARK: Root-set confinement

    @Test func theReadVerbRefusesAPathOutsideTheRootSet() async throws {
        let context = try await Self.makeContext()
        let outside = try Self.makeTemporaryDirectory(label: "outside")
            .appendingPathComponent("secret.txt")
        try "outside the roots".write(to: outside, atomically: true, encoding: .utf8)

        let registry = try await ToolCatalog.makeRegistry(context: context).registry
        let result = try await Self.invokeRead(in: registry, path: outside.path)

        #expect(result.correction != nil)
        #expect(result.lines.isEmpty)
    }

    @Test func theReadVerbAcceptsAPathInAnAdditionalRoot() async throws {
        let additionalRoot = try Self.makeTemporaryDirectory(label: "additional")
        let insideFile = additionalRoot.appendingPathComponent("inside.txt")
        try "inside the additional root".write(to: insideFile, atomically: true, encoding: .utf8)
        let context = try await Self.makeContext(additionalRoots: [additionalRoot])

        let registry = try await ToolCatalog.makeRegistry(context: context).registry
        let result = try await Self.invokeRead(in: registry, path: insideFile.path)

        #expect(result.correction == nil)
        #expect(!result.lines.isEmpty)
    }

    // MARK: The code context group

    /// The code context tools mount inside Multitool, and not as direct
    /// session tools. Multitool gives each operation of the three fused
    /// tools its own verb in the `tools.code_context` group.
    @Test func aDefaultRegistryMountsTheCodeContextGroup() async throws {
        let context = try await Self.makeContext(keepsCodeContext: true)

        let built = try await ToolCatalog.makeRegistry(context: context)

        let prefix = "\(ToolCatalog.codeContextGroupName)."
        let verbs = built.registry.surface.entries.map(\.path).filter { $0.hasPrefix(prefix) }
        let operationCount = CodeContextTools.operationNames.values.map(\.count).reduce(0, +)
        #expect(verbs.count == operationCount)
        for verb in ["getSymbol", "getCallgraph", "getBlastradius"] {
            #expect(verbs.contains(prefix + verb))
        }
        let stop = try #require(built.codeContextStop)
        await stop()
    }

    /// The catalog does not wait for the index. `CodeContext.start()` does
    /// one full index pass with an embedding of each chunk, and for a large
    /// repository that pass is longer than a client waits for `session/new`
    /// (the SWE-bench run of 2026-09-18). Here the embedder never answers
    /// until the task is cancelled, and the workspace holds a source file,
    /// so a catalog that waits for `start()` never returns. The stop closure
    /// must return too: it cancels the start task before it stops the context.
    @Test(.timeLimit(.minutes(1)))
    func theCatalogDoesNotWaitForTheCodeContextIndex() async throws {
        var loader = StubModelLoader()
        loader.makeEmbeddingContainer = { _ in NeverAnsweringEmbeddingContainer() }
        let context = try await Self.makeContext(loader: loader, keepsCodeContext: true)
        try "func answer() -> Int { 42 }\n".write(
            to: context.workingDirectory.appendingPathComponent("Answer.swift"),
            atomically: true, encoding: .utf8)

        let built = try await ToolCatalog.makeRegistry(context: context)

        let stop = try #require(built.codeContextStop)
        await stop()
    }

    /// With `semanticSearch` off, the index never calls the profile's
    /// embedder.
    @Test func semanticSearchOffCallsNoEmbedder() async throws {
        let embedder = RecordingEmbeddingContainer(wrapping: StubEmbeddingContainer())
        var loader = StubModelLoader()
        loader.makeEmbeddingContainer = { _ in embedder }
        let context = try await Self.makeContext(loader: loader) { configuration in
            configuration.tools.codeContext = .enabled(
                CodeContextToolOptions(semanticSearch: false))
        }
        try "func answer() -> Int { 42 }\n".write(
            to: context.workingDirectory.appendingPathComponent("Answer.swift"),
            atomically: true, encoding: .utf8)

        let built = try await ToolCatalog.makeRegistry(context: context)
        // With the profile's embedder, the index reaches it in less than
        // this time for the one file of the workspace.
        try await Task.sleep(for: .seconds(2))
        let stop = try #require(built.codeContextStop)
        await stop()

        #expect(embedder.batches.isEmpty)
    }

    @Test func aDisabledCodeContextSectionMountsNoCodeContextGroup() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.codeContext = .disabled
        }

        let built = try await ToolCatalog.makeRegistry(context: context)

        let prefix = "\(ToolCatalog.codeContextGroupName)."
        #expect(!built.registry.surface.entries.contains { $0.path.hasPrefix(prefix) })
        #expect(built.codeContextStop == nil)
    }

    // MARK: The web group

    /// With no configuration and an empty environment, the surface has the
    /// two web verbs. The capability sends no request when it mounts.
    @Test func aDefaultRegistryMountsTheWebVerbs() async throws {
        let context = try await Self.makeContext(environment: [:], keepsCodeContext: true)

        let built = try await ToolCatalog.makeRegistry(context: context)

        let paths = built.registry.surface.entries.map(\.path)
        #expect(paths.contains(Self.webSearchPath))
        #expect(paths.contains(Self.webFetchPath))
        let stop = try #require(built.codeContextStop)
        await stop()
    }

    /// `tools.web.enabled: false` mounts no web verb.
    @Test func aWebSectionThatIsNotEnabledMountsNoWebVerb() async throws {
        let context = try await Self.makeContext(environment: [:]) { configuration in
            configuration.tools.web = .enabled(WebToolOptions(enabled: false))
        }

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        #expect(!registry.surface.entries.contains { $0.group == Self.webNoun })
        #expect(registry.surface.entries.contains { $0.path == Self.readVerbPath })
    }

    // MARK: The git group

    /// With the default configuration, the surface has each read-only git
    /// verb. The capability reads no repository when it mounts.
    @Test func aDefaultRegistryMountsTheGitVerbs() async throws {
        let context = try await Self.makeContext()

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        let paths = Set(registry.surface.entries.map(\.path))
        for verbPath in GitVerbSupport.verbPaths {
            #expect(paths.contains(verbPath), "the surface has no \(verbPath)")
        }
    }

    /// `tools.git: false` and `tools.git.enabled: false` each mount no
    /// `tools.git` namespace, and the other capabilities stay.
    @Test(arguments: [
        ToolSection<GitToolOptions>.disabled, .enabled(GitToolOptions(enabled: false)),
    ])
    func aGitSectionThatIsOffMountsNoGitNamespace(section: ToolSection<GitToolOptions>) async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.git = section
        }

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        #expect(!registry.surface.entries.contains { $0.group == GitVerbSupport.gitNoun })
        #expect(registry.surface.entries.contains { $0.path == Self.readVerbPath })
    }

    /// In a git repository, `tools.git.status` reads the session working
    /// directory and gives the current branch.
    @Test func theGitStatusVerbGivesTheCurrentBranch() async throws {
        let context = try await Self.makeContext()
        try GitVerbSupport.makeRepository(in: context.workingDirectory, branch: Self.repositoryBranch)

        let registry = try await ToolCatalog.makeRegistry(context: context).registry
        let status = try await GitVerbSupport.invokeStatus(in: registry)

        #expect(status.correction == nil)
        #expect(status.branch == Self.repositoryBranch)
    }

    // MARK: The skills registry

    @Test func theSkillsRegistryWatchesForCommandUpdates() async throws {
        let context = try await Self.makeContext()

        let made = await ToolCatalog.makeSkillsRegistry(context: context)
        let registry = try #require(made)

        #expect(registry.commandUpdates != nil)
    }

    @Test func aDisabledSkillsSectionBuildsNoSkillsRegistry() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.skills = .disabled
        }

        let made = await ToolCatalog.makeSkillsRegistry(context: context)
        #expect(made == nil)
    }
}

/// An embedding container that never answers. `embed(texts:)` sleeps until
/// its task is cancelled, and then it throws the cancellation.
private final class NeverAnsweringEmbeddingContainer: LoadedEmbeddingContainer {
    /// An arbitrary vector length; no vector is ever made.
    let dimension = 8

    /// Waits for the cancellation of the task.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await Task.sleep(for: .seconds(3600))
        return []
    }
}

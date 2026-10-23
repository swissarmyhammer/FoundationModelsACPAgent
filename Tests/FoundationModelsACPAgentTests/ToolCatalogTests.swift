import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsCodeContext
import FoundationModelsMultitool
import FoundationModelsRouter
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

/// The composition matrix of `ToolCatalog`: the
/// session tools a default context mounts, the enable and disable codec,
/// the root-set confinement of the files verbs, and the watched skills
/// registry.
///
/// The per-verb argument and output structs of the capability modules are
/// internal upstream, so composition is asserted through the built
/// `APISurface.entries` paths, and a verb is exercised through the public
/// `ToolInvoker.invoke(_:content:)` door with its wire JSON.
@Suite struct ToolCatalogTests {
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

    /// The noun the environment capability owns on the surface.
    private static let environmentNoun = "environment"

    /// The surface path of the environment `now` verb.
    private static let environmentNowPath = "environment.now"

    /// The surface path of each verb that the environment capability mounts.
    private static let environmentVerbPaths = [
        "environment.variables", "environment.os", environmentNowPath,
    ]

    /// The format of the `date` field of the `now` verb: `yyyy-MM-dd`.
    private static let nowDatePattern = #"^\d{4}-\d{2}-\d{2}$"#

    /// The branch of the one commit of the temporary git repository.
    private static let repositoryBranch = "catalog-branch"

    /// The git ref `HEAD`: the branch name that `tools.git.changes` gives for
    /// a detached HEAD, and the ref of the old side of `tools.git.diff`.
    private static let headReference = "HEAD"

    /// The git range of the last commit of the temporary git repository.
    private static let lastCommitRange = "HEAD~1..HEAD"

    /// The `entityType` of a `tools.git.diff` change that holds changed
    /// lines that no entity holds.
    private static let uncoveredLinesEntityType = "lines"

    /// The task the embedder proof gives the mounted `searchTools`.
    private static let embedderTask = "read one text file from the workspace"

    /// The selection the scripted flash slot answers, in the shape
    /// `SelectionTier` decodes, so the search completes.
    private static let flashSelectionJSON = #"{"ids":["\#(readVerbPath)"]}"#

    /// The surface path of the one verb of the `settings` tool: the camelCase
    /// form of its op `query settings` under the noun `settings`.
    private static let settingsVerbPath = "settings.querySettings"

    /// The key path of `compaction.trigger`.
    private static let triggerKeyPath = SettingsGraphFixture.triggerKeyPath

    /// The value of `compaction.trigger` that the session level gets.
    private static let sessionTrigger = 0.9

    /// An `updateSetting` mutation of ``triggerKeyPath`` on the session level,
    /// with no `cwd`: the session folder of the tool applies.
    private static let sessionTriggerMutation =
        "mutation { updateSetting(input: {keyPath: [\"compaction\", \"trigger\"], value: \(sessionTrigger), level: SESSION}) { level } }"

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
    /// profile. The configuration is ``AgentConfiguration/withoutMarketplaces``,
    /// thus the skills source needs no network.
    ///
    /// - Parameters:
    ///   - additionalRoots: The session's additional roots, in order.
    ///   - loader: The loader the stub profile resolves through. The
    ///     default vends the echo containers.
    ///   - environment: The process environment the web capability reads
    ///     its API keys from. The default is empty, thus no test reads a
    ///     key of the machine that runs it.
    ///   - keepsCodeContext: `true` keeps the default `codeContext:`
    ///     section. Each registry build then leases a `CodeContext`, and
    ///     the test must release `codeContextLease` before it ends. The
    ///     default `false` turns the section off, thus a test that does
    ///     not test the code context starts none.
    ///   - hasSettingsStore: `true` gives the context the `settings` endpoint
    ///     of a settings store over its settings folders and an empty
    ///     in-memory secret store, thus the registry mounts the `settings`
    ///     tool. The default `false` gives no endpoint.
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
        hasSettingsStore: Bool = false,
        configure: (inout AgentConfiguration) -> Void = { _ in }
    ) async throws -> CatalogContext {
        var configuration = AgentConfiguration.withoutMarketplaces
        if !keepsCodeContext {
            configuration.tools.codeContext = .disabled
        }
        configure(&configuration)
        let settingsFolders = try SettingsFoldersFixture.make(label: "ToolCatalogTests", environment: environment)
        return CatalogContext(
            workingDirectory: try makeTemporaryDirectory(label: "work"),
            additionalRoots: additionalRoots,
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: try makeTemporaryDirectory(label: "cache"),
                loader: loader),
            settingsFolders: settingsFolders,
            environment: environment,
            settingsEndpoint: hasSettingsStore
                ? try SettingsGraph(
                    store: SettingsStore(settingsFolders: settingsFolders, secretStore: InMemorySecretStore()))
                : nil)
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

        #expect(surface.tools.map(\.name) == MountOrder.defaultToolNames)
        await surface.shutdown()
    }

    /// The config cannot turn the skills tool off: the `tools.skills: false`
    /// that the loader reads gives the default skills options, and the
    /// session mounts the `skills` tool. The test empties the marketplace
    /// list of those options only to keep the unit test off the network.
    @Test func aConfigThatTurnsTheSkillsToolOffStillMountsTheSkillsTool() async throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            "tools:\n  skills: false\n")
        let context = try await Self.makeContext { configuration in
            configuration.tools.skills = loaded.configuration.tools.skills
            configuration.tools.skills.marketplaces = []
        }

        let surface = try await ToolCatalog.sessionSurface(context: context)

        #expect(loaded.configuration.tools.skills == SkillsToolOptions())
        #expect(surface.tools.map(\.name) == MountOrder.defaultToolNames)
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
        let lease = try #require(built.codeContextLease)
        await lease.release()
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
        let lease = try #require(built.codeContextLease)
        await lease.release()
    }

    /// The catalog does not wait for the index. `CodeContext.start()` does
    /// one full index pass with an embedding of each chunk, and for a large
    /// repository that pass is longer than a client waits for `session/new`
    /// (the SWE-bench run of 2026-09-18). Here the embedder never answers
    /// until the task is cancelled, and the workspace holds a source file,
    /// so a catalog that waits for `start()` never returns. The release of
    /// the lease must return too: the last release cancels the start task
    /// before it stops the context.
    @Test
    func theCatalogDoesNotWaitForTheCodeContextIndex() async throws {
        var loader = StubModelLoader()
        loader.makeEmbeddingContainer = { _ in NeverAnsweringEmbeddingContainer() }
        let context = try await Self.makeContext(loader: loader, keepsCodeContext: true)
        try "func answer() -> Int { 42 }\n".write(
            to: context.workingDirectory.appendingPathComponent("Answer.swift"),
            atomically: true, encoding: .utf8)

        let built = try await ToolCatalog.makeRegistry(context: context)

        let lease = try #require(built.codeContextLease)
        await lease.release()
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
        // The first index pass reads the one file of the workspace. With
        // the profile's embedder it would call the embedder in that pass.
        let lease = try #require(built.codeContextLease)
        await lease.context.waitForFirstIndexPass()
        await lease.release()

        #expect(embedder.batches.isEmpty)
    }

    @Test func aDisabledCodeContextSectionMountsNoCodeContextGroup() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.codeContext = .disabled
        }

        let built = try await ToolCatalog.makeRegistry(context: context)

        let prefix = "\(ToolCatalog.codeContextGroupName)."
        #expect(!built.registry.surface.entries.contains { $0.path.hasPrefix(prefix) })
        #expect(built.codeContextLease == nil)
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
        let lease = try #require(built.codeContextLease)
        await lease.release()
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

    /// On a detached HEAD, `tools.git.changes` with no `branch` reads HEAD:
    /// it gives no correction, and the result names the branch `HEAD`.
    @Test func theGitChangesVerbReadsADetachedHeadWithNoBranch() async throws {
        let context = try await Self.makeContext()
        try GitVerbSupport.makeDetachedRepository(in: context.workingDirectory, branch: Self.repositoryBranch)

        let registry = try await ToolCatalog.makeRegistry(context: context).registry
        let changes = try await GitVerbSupport.invokeChanges(in: registry, arguments: [:])

        #expect(changes.correction == nil)
        #expect(changes.branch == Self.headReference)
    }

    /// On a detached HEAD, `tools.git.changes` with the range of the last
    /// commit lists the file of that commit, and only that file.
    @Test func theGitChangesVerbReadsARangeOnADetachedHead() async throws {
        let context = try await Self.makeContext()
        try GitVerbSupport.makeDetachedRepository(in: context.workingDirectory, branch: Self.repositoryBranch)

        let registry = try await ToolCatalog.makeRegistry(context: context).registry
        let changes = try await GitVerbSupport.invokeChanges(
            in: registry, arguments: ["range": Self.lastCommitRange])

        #expect(changes.correction == nil)
        #expect(changes.files == [GitVerbSupport.sourceFileName])
    }

    /// `tools.git.diff` of a tracked source file at HEAD against the work
    /// tree reports a comment line added at the end of the file, as changed
    /// lines that no entity holds.
    @Test func theGitDiffVerbReportsACommentLineAddedAtTheEndOfAFile() async throws {
        let context = try await Self.makeContext()
        try GitVerbSupport.makeDetachedRepository(in: context.workingDirectory, branch: Self.repositoryBranch)
        try GitVerbSupport.appendCommentLine(in: context.workingDirectory)

        let registry = try await ToolCatalog.makeRegistry(context: context).registry
        let diff = try await GitVerbSupport.invokeDiff(
            in: registry,
            left: "\(GitVerbSupport.sourceFileName)@\(Self.headReference)",
            right: GitVerbSupport.sourceFileName)

        #expect(diff.correction == nil)
        #expect(
            diff.changes.contains {
                $0.entityType == Self.uncoveredLinesEntityType && $0.filePath == GitVerbSupport.sourceFileName
            })
    }

    // MARK: The environment group

    /// The slice of the wire result of the `now` verb that these tests
    /// assert on. The output struct of the verb is internal upstream; the
    /// wire JSON is the public shape.
    private struct NowVerbResult: Decodable {
        /// The local date, as `yyyy-MM-dd`.
        let date: String

        /// Why the verb gave no date, or `nil` when the date stands.
        let correction: String?
    }

    /// With the default configuration, the surface has each environment
    /// verb. The capability reads nothing from the process when it mounts.
    @Test func aDefaultRegistryMountsTheEnvironmentVerbs() async throws {
        let context = try await Self.makeContext()

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        let paths = Set(registry.surface.entries.map(\.path))
        for verbPath in Self.environmentVerbPaths {
            #expect(paths.contains(verbPath), "the surface has no \(verbPath)")
        }
    }

    /// `tools.environment: false` and `tools.environment.enabled: false`
    /// each mount no `tools.environment` namespace, and the other
    /// capabilities stay.
    @Test(arguments: [
        ToolSection<EnvironmentToolOptions>.disabled,
        .enabled(EnvironmentToolOptions(enabled: false)),
    ])
    func anEnvironmentSectionThatIsOffMountsNoEnvironmentNamespace(
        section: ToolSection<EnvironmentToolOptions>
    ) async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.environment = section
        }

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        #expect(!registry.surface.entries.contains { $0.group == Self.environmentNoun })
        #expect(registry.surface.entries.contains { $0.path == Self.readVerbPath })
    }

    /// `tools.environment.now`, called through the registry with no time
    /// zone, gives the local date and no correction.
    @Test func theEnvironmentNowVerbGivesTheDate() async throws {
        let context = try await Self.makeContext()
        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        let now: NowVerbResult = try await FilesVerbSupport.invoke(
            try #require(registry.tools[Self.environmentNowPath]), arguments: [:])

        #expect(now.correction == nil)
        #expect(
            now.date.range(of: Self.nowDatePattern, options: .regularExpression) != nil,
            "the date is \(now.date)")
    }

    // MARK: The settings tool

    /// The slice of the wire result of an `updateSetting` mutation through the
    /// `settings` verb that these tests assert on: the level of the merged
    /// setting after the change.
    private struct SettingsSetResult: Decodable {
        /// The `data` object of the GraphQL response.
        struct ResponseData: Decodable {
            /// The result of the `updateSetting` mutation, or `nil` when it
            /// failed.
            let updateSetting: SetResult?
        }

        /// The fields of the `Setting` that the mutation selects.
        struct SetResult: Decodable {
            /// The layer that set the merged value.
            let level: String
        }

        /// The `data` object, or `nil` when the response has none.
        let data: ResponseData?
    }

    /// A context with a settings store mounts the one verb of the
    /// `settings` tool in the registry, under the noun `settings`.
    @Test func aContextWithASettingsStoreMountsTheSettingsVerb() async throws {
        let context = try await Self.makeContext(hasSettingsStore: true)

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        let paths = registry.surface.entries.filter { $0.group == SettingsGraph.endpointName }.map(\.path)
        #expect(paths == [Self.settingsVerbPath])
    }

    /// A context with no settings store mounts no `settings` noun.
    @Test func aContextWithNoSettingsStoreMountsNoSettingsNoun() async throws {
        let context = try await Self.makeContext()

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        #expect(!registry.surface.entries.contains { $0.group == SettingsGraph.endpointName })
    }

    /// The `settings` tool is only in the registry: the top-level tools of
    /// the session do not change.
    @Test func theSettingsToolIsNotATopLevelTool() async throws {
        let context = try await Self.makeContext(hasSettingsStore: true)

        let surface = try await ToolCatalog.sessionSurface(context: context)

        let names = surface.tools.map(\.name)
        #expect(names == MountOrder.defaultToolNames)
        #expect(!names.contains(SettingsGraph.endpointName))
    }

    /// A call of the `settings` verb through the registry with no `cwd`
    /// writes the session level of the working directory of the session.
    @Test func aSettingsCallThroughTheRegistryWritesTheSessionLevelOfTheSession() async throws {
        let context = try await Self.makeContext(hasSettingsStore: true)
        let endpoint = try #require(context.settingsEndpoint)
        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        let answer: SettingsSetResult = try await FilesVerbSupport.invoke(
            try #require(registry.tools[Self.settingsVerbPath]), arguments: ["query": Self.sessionTriggerMutation])

        #expect(answer.data?.updateSetting?.level == SettingsGraphFixture.sessionLevel)
        let stored = try GraphQLReply(
            await endpoint.execute(
                query: SettingsGraphFixture.settingQuery,
                variables: SettingsGraphFixture.variables(keyPath: Self.triggerKeyPath, cwd: context.workingDirectory),
                operationName: nil, viewer: nil)
        ).object("setting")
        #expect(stored["value"] as? Double == Self.sessionTrigger)
        #expect(stored["level"] as? String == SettingsGraphFixture.sessionLevel)
    }

    // MARK: The skills registry

    @Test func theSkillsRegistryWatchesForCommandUpdates() async throws {
        let context = try await Self.makeContext()

        let registry = await ToolCatalog.makeSkillsSource(context: context).registry

        #expect(registry.commandUpdates != nil)
    }

    // MARK: The language server install

    /// The install settings of the language servers keep their record in the
    /// home, and follow the `autoInstall` option.
    @Test(arguments: [true, false])
    func theLanguageServerInstallKeepsItsRecordInTheHome(autoInstall: Bool) {
        let home = AgentHomeFixture.make(label: "ToolCatalogTests-languageServers")

        let install = ToolCatalog.makeLanguageServerInstall(
            options: CodeContextToolOptions(autoInstall: autoInstall), home: home)

        #expect(install.failureRecordDirectory == home.languageServerInstallRecordDirectory)
        #expect(install.isEnabled == autoInstall)
    }
}

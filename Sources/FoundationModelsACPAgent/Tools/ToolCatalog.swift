import Foundation
import FoundationModels
import FoundationModelsAgents
import FoundationModelsCodeContext
import FoundationModelsMultitool
import FoundationModelsRanker
import FoundationModelsRouter
import FoundationModelsSkills

/// The surface one session mounts: the composed
/// tools in mount order, and the pool that holds every MCP server, spawned
/// subprocess and the attached surface refresher.
///
/// The session lifecycle owns the pool: after the session sweep it calls
/// `MCPServerPool.shutdownAll()`, which stops the refresher first, then
/// disconnects each server and ends each subprocess. A surface with no MCP
/// server holds an empty pool, whose `shutdownAll()` does nothing.
public struct SessionSurface: Sendable {
    /// The composed tools, in mount order.
    public let tools: [any FoundationModels.Tool]

    /// The pool the session lifecycle shuts down after the session sweep.
    public let serverPool: MCPServerPool

    /// The mounted `tools.files.read` verb, or `nil` when the files
    /// section is off. The prompt's resource-link resolver reads
    /// through it, so a linked file is bounded by the same
    /// root set the model reads under.
    public let filesReadVerb: (any FoundationModels.Tool)?

    /// The host-owned live shell output stream, or
    /// `nil` when the shell section is off. The session start hands it
    /// to the terminal projection, the prompt reads settlements
    /// through its `snapshot(for:)`, and the session-close task calls
    /// its `finish()` at teardown.
    public let shellOutput: ShellOutputChunkStream?

    /// Stops the code context of the session — its index loop, its file
    /// watcher and its language servers — or `nil` when the `codeContext:`
    /// section is off.
    public let codeContextStop: (@Sendable () async -> Void)?

    /// The outcome of each MCP server of the session, in mount order: the
    /// config-derived servers first, then the client-supplied servers, then
    /// the refused client-supplied servers that have a name. The MCP server
    /// status report of the session reads it.
    let mcpServerOutcomes: [MCPComposition.ServerOutcome]

    /// The connected MCP servers of the session, in mount order. Only a
    /// read needs them, for example the check of their user presence; the
    /// ``serverPool`` owns their shutdown.
    let mcpServers: [FoundationModelsMultitool.MCPServer]

    /// The settle period of the root session of this surface, in seconds:
    /// the ``CatalogContext/inlineSettleGrace`` that the surface also gave
    /// the agent environment. The session lifecycle gives it to
    /// `RoutedLLM.makeBudgetedSession(...inlineSettleGrace:)`, thus a
    /// `start agent` call of the root session and the background calls of
    /// each agent run wait for the same period.
    public let inlineSettleGrace: TimeInterval

    /// The mounted `agents` tool, its runner and its environment, or `nil`
    /// for a surface that the catalog did not compose, such as the empty
    /// surface of a replay-only session.
    let agents: AgentsMount?

    /// The join of each tool run of the session to its SDK tool call (tasks
    /// ^9xk3xf4 and ^zbcrex8). The surface owns it, because the shell output
    /// stream and the agent environment of the surface live for the whole
    /// session. The projection of each prompt writes the entries of the root
    /// runs, the agent environment writes the entries of the runs of each
    /// agent run, and the terminal stream of the session reads each entry.
    let runCallJoins: RunCallJoinTable

    /// Makes a session surface with no MCP server outcome and no `agents`
    /// tool.
    ///
    /// - Parameters:
    ///   - tools: The composed tools, in mount order.
    ///   - serverPool: The pool the session lifecycle shuts down.
    ///   - filesReadVerb: The mounted read verb, or `nil` when the
    ///     files section is off.
    ///   - shellOutput: The host-owned live shell output stream, or
    ///     `nil` when the shell section is off.
    ///   - codeContextStop: Stops the code context of the session, or
    ///     `nil` when the code context section is off.
    ///   - inlineSettleGrace: The settle period of the root session.
    ///     Defaults to ``CatalogContext/defaultInlineSettleGrace``.
    public init(
        tools: [any FoundationModels.Tool],
        serverPool: MCPServerPool,
        filesReadVerb: (any FoundationModels.Tool)? = nil,
        shellOutput: ShellOutputChunkStream? = nil,
        codeContextStop: (@Sendable () async -> Void)? = nil,
        inlineSettleGrace: TimeInterval = CatalogContext.defaultInlineSettleGrace
    ) {
        self.init(
            tools: tools, serverPool: serverPool, filesReadVerb: filesReadVerb,
            shellOutput: shellOutput, codeContextStop: codeContextStop, mcpServerOutcomes: [],
            inlineSettleGrace: inlineSettleGrace, agents: nil, runCallJoins: RunCallJoinTable())
    }

    /// Makes a session surface.
    ///
    /// - Parameters:
    ///   - tools: The composed tools, in mount order.
    ///   - serverPool: The pool the session lifecycle shuts down.
    ///   - filesReadVerb: The mounted read verb, or `nil` when the
    ///     files section is off.
    ///   - shellOutput: The host-owned live shell output stream, or
    ///     `nil` when the shell section is off.
    ///   - codeContextStop: Stops the code context of the session, or
    ///     `nil` when the code context section is off.
    ///   - mcpServerOutcomes: The outcome of each MCP server, in mount
    ///     order.
    ///   - mcpServers: The connected MCP servers, in mount order. Empty by
    ///     default.
    ///   - inlineSettleGrace: The settle period of the root session.
    ///   - agents: The mounted `agents` tool, or `nil` for a surface that
    ///     the catalog did not compose.
    ///   - runCallJoins: The join table of the session, which the agent
    ///     environment of `agents` writes.
    init(
        tools: [any FoundationModels.Tool],
        serverPool: MCPServerPool,
        filesReadVerb: (any FoundationModels.Tool)?,
        shellOutput: ShellOutputChunkStream?,
        codeContextStop: (@Sendable () async -> Void)?,
        mcpServerOutcomes: [MCPComposition.ServerOutcome],
        mcpServers: [FoundationModelsMultitool.MCPServer] = [],
        inlineSettleGrace: TimeInterval,
        agents: AgentsMount?,
        runCallJoins: RunCallJoinTable
    ) {
        self.tools = tools
        self.serverPool = serverPool
        self.filesReadVerb = filesReadVerb
        self.shellOutput = shellOutput
        self.codeContextStop = codeContextStop
        self.mcpServerOutcomes = mcpServerOutcomes
        self.mcpServers = mcpServers
        self.inlineSettleGrace = inlineSettleGrace
        self.agents = agents
        self.runCallJoins = runCallJoins
    }

    /// This surface with `hostTools` after its own tools
    /// (``RoutedACPAgent/registerHostTools(_:)``). Each other part does not
    /// change.
    ///
    /// - Parameter hostTools: The tools of the host, in order.
    /// - Returns: The surface with the host tools.
    func appending(hostTools: [any FoundationModels.Tool]) -> SessionSurface {
        guard !hostTools.isEmpty else { return self }
        return SessionSurface(
            tools: tools + hostTools,
            serverPool: serverPool,
            filesReadVerb: filesReadVerb,
            shellOutput: shellOutput,
            codeContextStop: codeContextStop,
            mcpServerOutcomes: mcpServerOutcomes,
            mcpServers: mcpServers,
            inlineSettleGrace: inlineSettleGrace,
            agents: agents,
            runCallJoins: runCallJoins)
    }

    /// Makes a surface that mounts nothing: no tool, no MCP server, no
    /// shell and no code context. A replay-only session gets it, because
    /// its working directory does not exist and each mount can make it.
    ///
    /// - Returns: The empty surface.
    static func makeEmpty() -> SessionSurface {
        SessionSurface(tools: [], serverPool: MCPServerPool())
    }

    /// Cancels each agent run of the surface, waits for each run to close
    /// its session, and starts no more runs.
    ///
    /// `RoutedSession.close()` does not know the runs that a `start agent`
    /// call started, thus the session lifecycle calls this before it closes
    /// the root session. A second call does nothing more.
    public func stopAgentRuns() async {
        await agents?.runner.stop()
    }

    /// Releases what the surface holds outside the session: it stops the
    /// agent runs, then the code context, then it shuts the server pool
    /// down. The session lifecycle calls this after the session sweep:
    /// a pool shutdown before the sweep drops the transports that the
    /// settling runs still need.
    public func shutdown() async {
        await stopAgentRuns()
        await codeContextStop?()
        await serverPool.shutdownAll()
    }
}

/// The tool catalog: the one place where this package
/// composes the tool surface a session mounts.
///
/// ══════════════════════════════════════════════════════════════════
///   ADD NEW CAPABILITIES HERE — and only here.
///   1. Decode the module's config section (a ``ToolSection`` in ``ToolsConfiguration``).
///   2. Append its `with…()` call to `makeRegistry(context:)` below.
///   3. Add a row to the table in README.md § Tools.
///   Nothing else in this package needs to change.
/// ══════════════════════════════════════════════════════════════════
///
/// The enable and disable rule is honored here. Each built-in capability
/// is on unless its section sets it off, so absence enables. A
/// capability whose section decodes as off gets no `with…()` call, is not
/// constructed, and never reaches the model.
public enum ToolCatalog {
    /// The dotfolder name the skills stack roots at:
    /// `<workingDirectory>/.skills` for the project layer, and with no root
    /// settings folder `~/.config/skills` for the user layer
    /// (``SettingsFolders``).
    static let skillsDotfolderName = "skills"

    /// The dotfolder name the agents stack roots at:
    /// `<workingDirectory>/.agents` for the project layer, and with no root
    /// settings folder `~/.config/agents` for the user layer
    /// (``SettingsFolders``). Each layer holds the agent folders
    /// `<id>/AGENT.md` and `agents/<id>/AGENT.md`, and its root `AGENT.md`
    /// is the default agent.
    static let agentsDotfolderName = "agents"

    /// The surface path of the files read verb, the door the prompt's
    /// resource-link resolver reads through.
    static let filesReadVerbPath = "files.read"

    /// The Multitool group the code context tools mount under. Multitool
    /// gives each operation of the three fused tools its own verb, so they
    /// render at `tools.code_context.<verb>`, for example
    /// `tools.code_context.getSymbol`.
    static let codeContextGroupName = "code_context"

    /// One built registry and the MCP composition around it: the recorded
    /// registrations for a rebuild, the pool that owns the servers, the
    /// connected servers for the refresher, and the outcome of each server.
    struct BuiltRegistry {
        /// The built registry, whose session tools a session mounts.
        let registry: MultiTool.Registry

        /// The recorded registrations of the build, which a surface
        /// rebuild renders again.
        let source: MultiTool.RegistrySource

        /// The pool that holds every MCP server the build recorded and
        /// every subprocess the composition spawned.
        let pool: MCPServerPool

        /// The connected MCP servers, in mount order — what the surface
        /// refresher watches.
        let mcpServers: [FoundationModelsMultitool.MCPServer]

        /// The outcome of each MCP server of the composition, in mount
        /// order — what the session surface keeps for the status report.
        let mcpServerOutcomes: [MCPComposition.ServerOutcome]

        /// The host-owned live shell output stream the build handed to
        /// `withShell(outputChunkStream:)`, or `nil`
        /// when the shell section is off.
        let shellOutput: ShellOutputChunkStream?

        /// Stops the started code context of the build, or `nil` when the
        /// `codeContext:` section is off.
        let codeContextStop: (@Sendable () async -> Void)?

        /// Waits until the code context of the build ended its first index
        /// pass, or `nil` when the `codeContext:` section is off. Only a test
        /// waits on it, to read a fact that the first pass makes true with no
        /// clock.
        var codeContextFirstIndexPass: (@Sendable () async -> Void)? = nil
    }

    /// Builds the composed session surface: the Multitool session tools —
    /// `searchTools` and `runCode`, in that mount order — the
    /// appended standalone `skills` tool, the appended
    /// standalone `agents` tool (``AgentsComposition``), and the server pool
    /// behind the mounted MCP verbs.
    ///
    /// The `skills` tool and the `agents` tool are always on. The `skills`
    /// tool of the root session is `AgentEnvironment.skillsTool`: the
    /// environment makes it from the one skills registry of the session,
    /// and each agent run gets the same tool.
    ///
    /// The MCP servers connect inside ``makeRegistry(context:)``, before
    /// the registry build, because Router's tool-instancing pipeline is
    /// synchronous. The surface refresher starts after the
    /// session tools are made and attaches to the pool, so a
    /// `tools/list_changed`, a reconnect, or a late catalog reaches the
    /// surface at the next submission boundary with no further host action.
    ///
    /// The mount takes two slots of the resolved profile: `flash` is the
    /// librarian every `searchTools` selection runs on (see
    /// ``makeSearchSelection(profile:)``), and `embedding` is the handle
    /// the discovery and did-you-mean searchers rank with. Without the
    /// embedder the registry reports `no embedder configured` on every
    /// search and ranks by keywords alone. The catalog is embedded at the
    /// first search, so the call still starts no task.
    ///
    /// - Parameters:
    ///   - context: What the builder calls need — the session root set,
    ///     the decoded configuration, the resolved profile, and the
    ///     client's per-session MCP servers.
    ///   - skills: The skills source the session already made, so the
    ///     `skills` tool, the slash-command source and the agent runs read
    ///     one registry and one marketplace store. With `nil`, the call
    ///     makes its own through ``makeSkillsSource(context:)``.
    /// - Returns: The composed surface.
    /// - Throws: Whatever the MCP composition, the registry build, the
    ///   session-tool construction, the skills assembly, or the agents
    ///   composition throws.
    public static func sessionSurface(
        context: CatalogContext, skills: SkillsSource? = nil
    ) async throws -> SessionSurface {
        let built = try await makeRegistry(context: context)
        let selection = makeSearchSelection(profile: context.profile)
        let embedder = ProfileEmbedding(embedder: context.profile.embedding)
        let mounted = try built.registry.makeSessionToolsAndStaging(
            selection: selection, embedder: embedder)
        let skillsSource =
            if let skills {
                skills
            } else {
                await makeSkillsSource(context: context)
            }
        let runCallJoins = RunCallJoinTable()
        let agents = try await AgentsComposition.compose(
            context: context, skills: skillsSource,
            runTools: AgentsComposition.makeRunTools(
                registry: built.registry, selection: selection, embedder: embedder),
            runCallJoins: runCallJoins)
        let tools = mounted.tools + makeStandaloneTools(agents: agents)
        await MCPComposition.startSurfaceRefresher(
            source: built.source, staging: mounted.staging, servers: built.mcpServers,
            pool: built.pool)
        return SessionSurface(
            tools: tools,
            serverPool: built.pool,
            filesReadVerb: built.registry.tools[Self.filesReadVerbPath],
            shellOutput: built.shellOutput,
            codeContextStop: built.codeContextStop,
            mcpServerOutcomes: built.mcpServerOutcomes,
            mcpServers: built.mcpServers,
            inlineSettleGrace: context.inlineSettleGrace,
            agents: agents,
            runCallJoins: runCallJoins)
    }

    /// The standalone tools that follow the Multitool session tools, in
    /// mount order: the `skills` tool of the agent environment, then the
    /// `agents` tool.
    ///
    /// - Parameter agents: The `agents` mount of the session.
    /// - Returns: The standalone tools, in mount order.
    static func makeStandaloneTools(agents: AgentsMount) -> [any FoundationModels.Tool] {
        [agents.environment.skillsTool, agents.tool]
    }

    /// Builds the Multitool registry over the enabled capability modules.
    ///
    /// Each enabled section becomes one builder call:
    /// `files` is confined to the session root set through
    /// `withFiles(root:additionalRoots:)`, and its search verbs skip
    /// each path that `tools.files.exclude` names (an exclude list that is
    /// `nil` excludes no path; the loader puts the dotfolder default in
    /// before the catalog sees the configuration), `shell` runs under a
    /// `SeatbeltSandbox` over the same root set — the sandbox is the only
    /// gate; there is no policy and no permission layer — `web`
    /// mounts `tools.web.search` and `tools.web.fetch` with the providers
    /// that ``CatalogContext/environment`` and `tools.web.apiKeys` select (see
    /// ``WebComposition``), `git` mounts the read-only `tools.git` verbs
    /// over the session working directory through `withGit(root:)`,
    /// `environment` mounts the read-only `tools.environment` verbs
    /// (`variables`, `os` and `now`) through `withEnvironment()`, and
    /// `mcp` composes the config-derived servers with the client's
    /// per-session ones, connects each one, and records the
    /// spawned subprocesses in the builder's pool. `codeContext` opens and
    /// starts one `CodeContext` over the session working directory, with the
    /// profile's embedding slot as its embedder, and mounts the operations
    /// of its three tools as the verbs of the `tools.code_context` group.
    /// With a ``CatalogContext/snapshotStore``, `snapshots` mounts the
    /// `tools.snapshots` verbs (`list`, `take` and `rollback`) over the
    /// snapshot store of the agent. It has no config section.
    ///
    /// - Parameter context: What the builder calls need.
    /// - Returns: The built registry and the MCP composition around it.
    /// - Throws: Whatever the MCP composition,
    ///   `withShell(storeDirectory:sandbox:outputChunkStream:defaultWorkingDirectory:)`,
    ///   `withMCP(servers:)` or
    ///   `buildRegistry()` throws.
    static func makeRegistry(context: CatalogContext) async throws -> BuiltRegistry {
        let builder = MultiTool.Builder()
        if case .enabled(let options) = context.configuration.tools.files {
            builder.withFiles(
                root: context.workingDirectory,
                additionalRoots: Set(context.additionalRoots),
                readOnly: options.readOnly,
                allowSymlinks: options.allowSymlinks,
                recordsChanges: options.recordsChanges,
                excludePatterns: options.exclude ?? [])
        }
        var shellOutput: ShellOutputChunkStream?
        if case .enabled(let options) = context.configuration.tools.shell {
            // The host-owned live view of every shell run: the
            // capability tees each raw chunk into it, the
            // terminal projection reads it, and the settlement reads
            // `snapshot(for:)` on the same stream.
            let stream = ShellOutputChunkStream()
            shellOutput = stream
            // Each shell command inherits the environment of the process,
            // not the context environment: `withShell(...)` of Multitool
            // takes no environment, and its runner starts each child with
            // the process environment.
            try SandboxComposition.composeShell(
                into: builder,
                options: options,
                configuration: context.configuration.sandbox,
                rootSet: [context.workingDirectory] + context.additionalRoots,
                outputChunkStream: stream)
        }
        WebComposition.compose(into: builder, context: context)
        if context.configuration.tools.git.mountedOptions != nil {
            builder.withGit(root: context.workingDirectory)
        }
        if context.configuration.tools.environment.mountedOptions != nil {
            // `tools.environment.variables` reads the environment of the
            // process, not the context environment: Multitool gives no public
            // way to give the capability an environment
            // (`EnvironmentContext.init` is internal).
            builder.withEnvironment()
        }
        // The `snapshots` capability reads the session key from
        // `HookSession.current` at call time, so it needs no key here.
        if let snapshotStore = context.snapshotStore {
            builder.withCapability(SnapshotsCapability(store: snapshotStore))
        }
        let composed = try await MCPComposition.connectServers(
            section: context.configuration.tools.mcp,
            clientServers: context.clientMCPServers,
            userPresence: context.userPresence)
        if !composed.servers.isEmpty {
            try await builder.withMCP(servers: composed.servers)
        }
        for process in composed.processes {
            await builder.serverPool.add(process: process)
        }
        // The code context is the last composition step, so a failure
        // before it leaves no started context behind.
        let codeContext = try await composeCodeContext(into: builder, context: context)
        let codeContextStop = codeContext?.stop
        do {
            return BuiltRegistry(
                registry: try builder.buildRegistry(),
                source: builder.registrySource,
                pool: builder.serverPool,
                mcpServers: composed.servers,
                mcpServerOutcomes: composed.outcomes,
                shellOutput: shellOutput,
                codeContextStop: codeContextStop,
                codeContextFirstIndexPass: codeContext?.firstIndexPass)
        } catch {
            await codeContextStop?()
            throw error
        }
    }

    /// Opens and starts the code context of the session, and queues its
    /// three tools in `builder` as the `tools.code_context` group, or does
    /// nothing when the `codeContext:` section is off.
    ///
    /// The workspace root is the session working directory. With
    /// `semanticSearch` on, the embedder is the profile's embedding slot,
    /// the same handle the discovery search ranks with. With it off, the
    /// context gets no embedder: its embedding layer is off, and
    /// `searchCode` answers with a clear error.
    ///
    /// `start()` returns before the first index pass, and the pass runs in
    /// the index loop of the context. Thus `session/new` does not wait for
    /// the index of a large repository. The verbs answer from what the
    /// index holds at the time of the call.
    ///
    /// - Parameters:
    ///   - builder: The builder that gets the tool group.
    ///   - context: The session whose working directory and profile the
    ///     code context reads.
    /// - Returns: The closure that stops the started code context, and the
    ///   closure that waits for its first index pass, or `nil` when the
    ///   section is off.
    /// - Throws: Whatever `CodeContext.init`, `start()` or
    ///   `CodeContextTools.make(context:)` throws. After a failure the
    ///   started context is stopped.
    static func composeCodeContext(
        into builder: MultiTool.Builder, context: CatalogContext
    ) async throws -> (stop: @Sendable () async -> Void, firstIndexPass: @Sendable () async -> Void)? {
        guard case .enabled(let options) = context.configuration.tools.codeContext else {
            return nil
        }
        let embedder: (any PooledEmbedding)? =
            options.semanticSearch
            ? ProfileEmbedding(embedder: context.profile.embedding)
            : nil
        let codeContext = try await CodeContext(
            rootDirectory: context.workingDirectory,
            embedder: embedder,
            autoInstall: LspAutoInstall(isEnabled: options.autoInstall))
        do {
            try await codeContext.start()
            builder.addGroup(
                named: codeContextGroupName, try CodeContextTools.make(context: codeContext))
        } catch {
            await codeContext.stop()
            throw error
        }
        return (
            stop: { await codeContext.stop() },
            firstIndexPass: { await codeContext.waitForFirstIndexPass() })
    }

    /// Builds the skills registry of the session over the dotfolder stack,
    /// and keeps the started marketplace store beside it. The skills tool
    /// is always on, thus each session has a skills source.
    ///
    /// The registry is built from the stack, never from bare roots:
    /// `SkillsRegistry(roots:)` maps every root to
    /// `.project`, which Skills renders untrusted, so a trusted defaults
    /// layer would be downgraded. `init(stack:)` passes the layers through
    /// unchanged, and Skills derives trust from each layer's `source`.
    /// `watch: true` is what makes `commandUpdates` non-nil for the
    /// slash-command registry.
    ///
    /// With a `marketplaces:` list in the section, the registry also reads
    /// one layer for each marketplace, below the full local stack. The
    /// store is started here, before the return: a cold cache fetches the
    /// repository and the ref of each source, thus the first session
    /// already has the skills. A fetch that fails gives a diagnostic and no
    /// layer; it does not fail the session.
    ///
    /// The agent registry reads the marketplace layers of the same store
    /// (``AgentsComposition``), thus a marketplace is fetched one time for
    /// the skills and the agents of a session.
    ///
    /// The store reads its cache folder and its read-only seed folder from
    /// ``CatalogContext/environment``: `SKILLS_MARKETPLACE_CACHE` and
    /// `SKILLS_MARKETPLACE_SEED`. With neither variable, the cache is the
    /// default folder under the home folder, and there is no seed. The
    /// dotfolder stack is the ``SettingsFolders/Kind/skills`` stack of
    /// ``CatalogContext/settingsFolders``: with a root settings folder its
    /// user layer is `<root>/_skills/`, and with no root it is the XDG user
    /// layer. It reads `SKILLS_DEFAULTS_DIR` from the environment of the
    /// settings folders.
    ///
    /// - Parameter context: The session whose working directory roots the
    ///   stack's project layer.
    /// - Returns: The skills source.
    public static func makeSkillsSource(context: CatalogContext) async -> SkillsSource {
        let options = context.configuration.tools.skills
        let stack = context.settingsFolders.stack(for: .skills, workingDirectory: context.workingDirectory)
        guard !options.marketplaces.isEmpty else {
            return SkillsSource(registry: SkillsRegistry(stack: stack, watch: true), marketplaces: nil)
        }
        let store = MarketplaceStore(
            sources: options.marketplaces, layout: SkillMarketplaceLayout.skills,
            cacheDirectory: MarketplaceStore.cacheDirectory(environment: context.environment),
            policy: MarketplacePolicy(), transport: LibGit2Transport(), environment: context.environment)
        await store.start()
        return SkillsSource(
            registry: SkillsRegistry(marketplaces: store, stack: stack, watch: true), marketplaces: store)
    }

    /// Makes the selection tier of `searchTools`: for each catalog, a
    /// configuration whose model is the flash slot of the profile.
    ///
    /// The selection must run on a model that is not the model of the
    /// session that calls `searchTools`. The tool is synchronous, so its
    /// body runs inside the open submission of the calling session, and a
    /// selection on the same model waits for that submission to end. Router
    /// refuses that wait. Thus the tier uses `flash`, and never forks the
    /// calling session.
    ///
    /// The tier names the ids of each prompt as the only choices, and asks
    /// for its `Selection` type, so each Router session gets the JSON Schema
    /// of that type as its grammar. The factory reads no id itself. Each
    /// session goes through one ``RoutedSelectionModel``, which closes the
    /// session when its one prompt ends.
    ///
    /// - Parameter profile: The resolved profile whose flash slot the tier
    ///   runs on. The model captures it, so the resident models outlive the
    ///   catalog context.
    /// - Returns: The selection factory that `searchTools` calls.
    static func makeSearchSelection(profile: LanguageModelProfile) -> SearchToolsTool.SelectionFactory {
        let model = RoutedSelectionModel(profile: profile)
        return { _ in SelectionConfig(model: model) }
    }
}

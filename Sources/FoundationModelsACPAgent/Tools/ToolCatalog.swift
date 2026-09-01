import Foundation
import FoundationModels
import FoundationModelsMultitool
import FoundationModelsRouter
import FoundationModelsSkills

/// The surface one session mounts (plan.md §11.1, §11.5): the composed
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

    /// Makes a session surface.
    ///
    /// - Parameters:
    ///   - tools: The composed tools, in mount order.
    ///   - serverPool: The pool the session lifecycle shuts down.
    public init(tools: [any FoundationModels.Tool], serverPool: MCPServerPool) {
        self.tools = tools
        self.serverPool = serverPool
    }
}

/// The tool catalog (plan.md §11.1): the one place where this package
/// composes the tool surface a session mounts.
///
/// ══════════════════════════════════════════════════════════════════
///   ADD NEW CAPABILITIES HERE — and only here.
///   1. Decode the module's config section (§11.2).
///   2. Append its `with…()` call to `makeRegistry(context:)` below.
///   3. Add a row to the table in README.md § Tools.
///   Nothing else in this package needs to change.
/// ══════════════════════════════════════════════════════════════════
///
/// The enable and disable rule (plan.md §11.2) is honored here: a
/// capability whose section decodes as off gets no `with…()` call, is not
/// constructed, and never reaches the model.
public enum ToolCatalog {
    /// The dotfolder name the skills stack roots at: `~/.config/skills`
    /// for the user layer and `<workingDirectory>/.skills` for the
    /// project layer.
    static let skillsDotfolderName = "skills"

    /// One built registry and the MCP composition around it: the recorded
    /// registrations for a rebuild, the pool that owns the servers, and
    /// the connected servers for the refresher.
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
    }

    /// Builds the composed session surface: the Multitool session tools —
    /// `searchTools`, `runCode`, `wait`, in that mount order — the
    /// appended standalone `skills` tool (plan.md §11.3), and the server
    /// pool behind the mounted MCP verbs (§11.5).
    ///
    /// The MCP servers connect inside ``makeRegistry(context:)``, before
    /// the registry build, because Router's tool-instancing pipeline is
    /// synchronous (plan.md §7.3). The surface refresher starts after the
    /// session tools are made and attaches to the pool, so a
    /// `tools/list_changed`, a reconnect, or a late catalog reaches the
    /// surface at the next turn boundary with no further host action.
    ///
    /// - Parameter context: What the builder calls need — the session
    ///   root set, the decoded configuration, the resolved profile, and
    ///   the client's per-session MCP servers.
    /// - Returns: The composed surface.
    /// - Throws: Whatever the MCP composition, the registry build, the
    ///   session-tool construction, or the skills assembly throws.
    public static func sessionSurface(context: CatalogContext) async throws -> SessionSurface {
        let built = try await makeRegistry(context: context)
        let mounted = try built.registry.makeSessionToolsAndStaging(
            librarian: context.profile.flash)
        var tools = mounted.tools
        if let skillsTool = try await makeSkillsTool(context: context) {
            tools.append(skillsTool)
        }
        await MCPComposition.startSurfaceRefresher(
            source: built.source, staging: mounted.staging, servers: built.mcpServers,
            pool: built.pool)
        return SessionSurface(tools: tools, serverPool: built.pool)
    }

    /// Builds the Multitool registry over the enabled capability modules.
    ///
    /// Each enabled section becomes one builder call (plan.md §11.3):
    /// `files` is confined to the session root set through
    /// `withFiles(root:additionalRoots:)` (§11.4), `shell` runs under a
    /// `SeatbeltSandbox` over the same root set — the sandbox is the only
    /// gate (§11.7); there is no policy and no permission layer — and
    /// `mcp` composes the config-derived servers with the client's
    /// per-session ones (§7.3, §11.5), connects each one, and records the
    /// spawned subprocesses in the builder's pool.
    ///
    /// - Parameter context: What the builder calls need.
    /// - Returns: The built registry and the MCP composition around it.
    /// - Throws: Whatever the MCP composition,
    ///   `withShell(storeDirectory:sandbox:)`, `withMCP(servers:)` or
    ///   `buildRegistry()` throws.
    static func makeRegistry(context: CatalogContext) async throws -> BuiltRegistry {
        let builder = MultiTool.Builder()
        if case .enabled(let options) = context.configuration.tools.files {
            builder.withFiles(
                root: context.workingDirectory,
                additionalRoots: Set(context.additionalRoots),
                readOnly: options.readOnly,
                allowSymlinks: options.allowSymlinks,
                recordsChanges: options.recordsChanges)
        }
        if case .enabled(let options) = context.configuration.tools.shell {
            try builder.withShell(
                storeDirectory: options.storeDirectory,
                sandbox: SeatbeltSandbox(
                    options: context.configuration.sandbox.sandboxOptions(
                        workingDirectory: context.workingDirectory,
                        additionalRoots: context.additionalRoots)))
        }
        let composed = try await MCPComposition.connectServers(
            section: context.configuration.tools.mcp,
            clientServers: context.clientMCPServers)
        if !composed.servers.isEmpty {
            try await builder.withMCP(servers: composed.servers)
        }
        for process in composed.processes {
            await builder.serverPool.add(process: process)
        }
        return BuiltRegistry(
            registry: try builder.buildRegistry(),
            source: builder.registrySource,
            pool: builder.serverPool,
            mcpServers: composed.servers)
    }

    /// Builds the skills registry over the dotfolder stack, or `nil` when
    /// the `skills:` section is off.
    ///
    /// The registry is built from the stack, never from bare roots
    /// (plan.md §14.2): `SkillsRegistry(roots:)` maps every root to
    /// `.project`, which Skills renders untrusted, so a trusted defaults
    /// layer would be downgraded. `init(stack:)` passes the layers through
    /// unchanged, and Skills derives trust from each layer's `source`.
    /// `watch: true` is what makes `commandUpdates` non-nil for the
    /// slash-command registry.
    ///
    /// - Parameter context: The session whose working directory roots the
    ///   stack's project layer.
    /// - Returns: The watched registry, or `nil` when skills is disabled.
    static func makeSkillsRegistry(context: CatalogContext) -> SkillsRegistry? {
        guard case .enabled = context.configuration.tools.skills else {
            return nil
        }
        return SkillsRegistry(
            stack: DotfolderStack(
                name: skillsDotfolderName,
                workingDirectory: context.workingDirectory),
            watch: true)
    }

    /// Builds the standalone `skills` tool, or `nil` when the `skills:`
    /// section is off.
    ///
    /// Skills is not a Multitool capability (plan.md §11.3): the tool is a
    /// plain `FoundationModels.Tool` appended beside the Multitool session
    /// tools, so a skill loads in one request/response step. Its selection
    /// tier runs on the profile's flash slot, and the session closure
    /// captures the profile itself so the resident models outlive the
    /// context.
    ///
    /// - Parameter context: The session whose profile backs the selection
    ///   tier.
    /// - Returns: The `skills` tool, or `nil` when skills is disabled.
    /// - Throws: Whatever `SkillsTool.make(registry:session:)` throws.
    static func makeSkillsTool(context: CatalogContext) async throws
        -> (any FoundationModels.Tool)?
    {
        guard let registry = makeSkillsRegistry(context: context) else {
            return nil
        }
        let profile = context.profile
        return try await SkillsTool.make(
            registry: registry,
            session: { instructions in
                SelectionAgentSession(session: profile.flash.makeSession(instructions: instructions))
            })
    }
}

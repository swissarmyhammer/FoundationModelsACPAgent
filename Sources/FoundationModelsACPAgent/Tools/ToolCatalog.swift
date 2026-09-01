import Foundation
import FoundationModels
import FoundationModelsMultitool
import FoundationModelsRouter
import FoundationModelsSkills

/// The tool catalog (plan.md §11.1): the one place where this package
/// composes the tool surface a session mounts.
///
/// ══════════════════════════════════════════════════════════════════
///   ADD NEW CAPABILITIES HERE — and only here.
///   1. Decode the module's config section (§11.2).
///   2. Append its `with…()` call to `sessionTools(context:)` below.
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

    /// Builds the composed tool array for `makeSession(tools:)`: the
    /// Multitool session tools — `searchTools`, `runCode`, `wait`, in that
    /// mount order — and the appended standalone `skills` tool (plan.md
    /// §11.3).
    ///
    /// The function is `async` because it must be: `withMCP(servers:)` is
    /// `async throws` (plan.md §11.1), and the mcp composition lands here
    /// when its task ships.
    ///
    /// - Parameter context: What the builder calls need — the session
    ///   root set, the decoded configuration, and the resolved profile.
    /// - Returns: The composed tools, in mount order.
    /// - Throws: Whatever the registry build, the session-tool
    ///   construction, or the skills assembly throws.
    public static func sessionTools(context: CatalogContext) async throws
        -> [any FoundationModels.Tool]
    {
        let registry = try makeRegistry(context: context)
        var tools = try registry.makeSessionTools(librarian: context.profile.flash)
        if let skillsTool = try await makeSkillsTool(context: context) {
            tools.append(skillsTool)
        }
        return tools
    }

    /// Builds the Multitool registry over the enabled capability modules.
    ///
    /// Each enabled section becomes one builder call (plan.md §11.3):
    /// `files` is confined to the session root set through
    /// `withFiles(root:additionalRoots:)` (§11.4), and `shell` runs under
    /// a `SeatbeltSandbox` over the same root set — the sandbox is the
    /// only gate (§11.7); there is no policy and no permission layer.
    ///
    /// - Parameter context: What the builder calls need.
    /// - Returns: The built registry.
    /// - Throws: Whatever `withShell(storeDirectory:sandbox:)` or
    ///   `buildRegistry()` throws.
    static func makeRegistry(context: CatalogContext) throws -> MultiTool.Registry {
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
        return try builder.buildRegistry()
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

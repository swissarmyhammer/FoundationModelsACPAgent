import Foundation
import FoundationModels
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsSkills
import Logging

/// The mounted `agents` tool of one session: the tool that the root session
/// gets, the runner of its agent runs, and the environment of those runs.
struct AgentsMount: Sendable {
    /// The `agents` tool of the root session.
    let tool: AgentsTool

    /// The runner of the agent runs of the session. The session lifecycle
    /// stops it before the root session closes, because the Router does not
    /// know the runs of a session.
    let runner: AgentRunner

    /// The environment of each agent run: the one skills registry, the
    /// `skills` tool of the root session and of the runs, the tools of the
    /// runs, and the settle period.
    let environment: AgentEnvironment
}

/// The composition of the standalone `agents` tool of FoundationModelsAgents
/// (task ^c4a6mwy).
///
/// **The tool is standalone, not a Multitool capability.** A `start agent`
/// call waits for its run for the settle period of the session. A run that
/// ends in that time gives its final message as the output of the call, and
/// a longer run goes to the background, and the session injects its final
/// message as a new message.
/// Inside a `runCode` snippet that wait would be a second background point,
/// thus the tool mounts beside `searchTools`, `runCode` and `skills`, the
/// same as the `skills` tool.
///
/// **One skills registry and one marketplace store.** The environment makes
/// the `skills` tool from the skills registry of the session, and the root
/// session mounts that tool, `AgentEnvironment.skillsTool`, in place of its
/// own. The agent registry reads the marketplace layers of the same store.
/// The host tool catalog never registers `skills`: the environment adds it.
///
/// **The tools of a run.** A run gets the Multitool session tools,
/// `searchTools` and `runCode`, by name, over the registry of the root
/// session, and the `skills` tool. The `tools` and `disallowedTools` keys
/// of an agent select from these names.
///
/// The `FoundationModelsAgents::` module selector names the tool catalog of
/// FoundationModelsAgents. This module has a ``ToolCatalog`` of its own, and
/// FoundationModelsAgents has an enum with the name of its module, thus
/// `FoundationModelsAgents.ToolCatalog` does not name the type.
enum AgentsComposition {
    /// Builds the agent registry, the environment, the runner and the
    /// `agents` tool. The `agents` tool is always on, thus each composed
    /// session has this mount.
    ///
    /// The agent registry reads the agent folders `agents/<name>/AGENT.md`
    /// of the `agents` dotfolder stack (``ToolCatalog/agentsDotfolderName``),
    /// and of each marketplace layer of the skills store. It does not watch:
    /// the schema of the tool is fixed when the tool is made, thus an agent
    /// that a later edit adds reaches the next session.
    ///
    /// - Parameters:
    ///   - context: The session whose configuration, profile, working
    ///     directory and settle period the composition reads.
    ///   - skills: The skills source of the session. The runs get a `skills`
    ///     tool over its registry, and the agent registry reads its
    ///     marketplace store.
    ///   - runTools: The tools that a run can get, by name.
    ///   - runCallJoins: The join table of the session. The environment
    ///     writes the entry of each tool run of each agent run into it
    ///     (``makeRunEventObserver(runCallJoins:)``).
    /// - Returns: The mount.
    /// - Throws: Whatever `AgentRegistry.load()`, `AgentEnvironment.make`
    ///   or `AgentsTool.make(context:)` throws.
    static func compose(
        context: CatalogContext, skills: SkillsSource, runTools: FoundationModelsAgents::ToolCatalog,
        runCallJoins: RunCallJoinTable
    ) async throws -> AgentsMount {
        let registry = makeAgentRegistry(context: context, marketplaces: skills.marketplaces)
        try await registry.load()
        let environment = try await AgentEnvironment.make(
            profile: context.profile,
            skills: skills.registry,
            skillsSelectionModel: RoutedSelectionModel(profile: context.profile),
            workingDirectory: context.workingDirectory,
            tools: runTools,
            inlineSettleGrace: context.inlineSettleGrace,
            runEventObserver: makeRunEventObserver(runCallJoins: runCallJoins))
        let runner = AgentRunner(registry: registry, environment: environment)
        let tool = try await AgentsTool.make(context: AgentsToolContext(runner: runner))
        return AgentsMount(tool: tool, runner: runner, environment: environment)
    }

    /// Makes the observer of the session events of each agent run of the
    /// session (task ^zbcrex8). It gives each event to `runCallJoins`, and
    /// the open record of a tool run writes "no join" for that run
    /// (``RunCallJoinTable/recordAgentRunEvent(_:)``).
    ///
    /// An agent run uses the shell capability of the root session, so the
    /// output of its shell runs comes on the shell output stream of the
    /// session, but its tool records go to the event stream of the agent run.
    /// The terminal stream holds a shell run that has no entry, and this
    /// entry releases it while the agent run continues.
    ///
    /// The environment is made for one session, and the table belongs to the
    /// same surface, so the observer needs no lookup from the run to the
    /// session. Each run calls the observer synchronously in its follow loop,
    /// child runs too, and two runs can call it at the same time. Thus the
    /// observer only takes the lock of the table, and it does not wait.
    ///
    /// - Parameter runCallJoins: The join table of the session.
    /// - Returns: The observer for `AgentEnvironment.make(runEventObserver:)`.
    static func makeRunEventObserver(runCallJoins: RunCallJoinTable) -> AgentEnvironment.RunEventObserver {
        { _, output in
            runCallJoins.recordAgentRunEvent(output)
        }
    }

    /// Makes the agent registry over the `agents` dotfolder stack, and over
    /// the marketplace store when the session has one. The registry reads
    /// no file until `load()`. The stack reads `AGENTS_DEFAULTS_DIR` and
    /// `XDG_CONFIG_HOME` from ``CatalogContext/environment``.
    ///
    /// - Parameters:
    ///   - context: The session whose working directory roots the project
    ///     layer of the stack, and whose environment gives the defaults
    ///     layer and the user layer of the stack.
    ///   - marketplaces: The started skills marketplace store, or `nil`.
    /// - Returns: The registry.
    static func makeAgentRegistry(
        context: CatalogContext, marketplaces: MarketplaceStore?
    ) -> AgentRegistry {
        let stack = DotfolderStack(
            name: ToolCatalog.agentsDotfolderName, workingDirectory: context.workingDirectory,
            environment: context.environment)
        guard let marketplaces else {
            return AgentRegistry(stack: stack)
        }
        return AgentRegistry(marketplaces: marketplaces, stack: stack)
    }

    /// Makes the tool catalog of the runs: one factory for each Multitool
    /// session tool of the root session, by its name.
    ///
    /// Each factory call makes a new pair of session tools over `registry`,
    /// thus each run gets its own `searchTools` and `runCode`, and gives the
    /// tool of the name. A `searchTools` and a `runCode` of one run come from
    /// two pairs; both read the same registry, and a registry holder keeps
    /// no state of a search, thus the two answer as one pair does. The probe
    /// pair below proves that the call succeeds for this registry. A later
    /// call over the same registry and the same selection gives the same
    /// result. A later call that fails is a defect, and
    /// ``freshSessionTool(named:registry:selection:embedder:fallback:)``
    /// records it.
    ///
    /// - Parameters:
    ///   - registry: The built Multitool registry of the root session.
    ///   - selection: The selection tier of `searchTools`.
    ///   - embedder: The embedder that `searchTools` and `runCode` rank with.
    /// - Returns: The tool catalog of the runs.
    /// - Throws: Whatever `MultiTool.Registry.makeSessionTools(selection:embedder:)`
    ///   throws for the probe pair.
    static func makeRunTools(
        registry: MultiTool.Registry,
        selection: @escaping SearchToolsTool.SelectionFactory,
        embedder: any PooledEmbedding
    ) throws -> FoundationModelsAgents::ToolCatalog {
        var tools = FoundationModelsAgents::ToolCatalog()
        for probe in try registry.makeSessionTools(selection: selection, embedder: embedder) {
            let name = probe.name
            tools.register(name) {
                freshSessionTool(
                    named: name, registry: registry, selection: selection, embedder: embedder,
                    fallback: probe)
            }
        }
        return tools
    }

    /// Makes a new pair of session tools over `registry`, and gives the tool
    /// of the name `name` from that pair.
    ///
    /// The probe pair of ``makeRunTools(registry:selection:embedder:)``
    /// proves that the call succeeds for this registry and gives a tool of
    /// this name. Thus a failure here is unexpected. A debug build stops at
    /// the assertion. A release build logs the failure and gives `fallback`,
    /// the tool of the probe pair, because the tool catalog of a run takes
    /// a factory that cannot throw.
    ///
    /// - Parameters:
    ///   - name: The name of the session tool, `searchTools` or `runCode`.
    ///   - registry: The built Multitool registry of the root session.
    ///   - selection: The selection tier of `searchTools`.
    ///   - embedder: The embedder that `searchTools` and `runCode` rank with.
    ///   - fallback: The tool of the same name from the probe pair.
    /// - Returns: The new tool, or `fallback` after a logged failure.
    static func freshSessionTool(
        named name: String,
        registry: MultiTool.Registry,
        selection: @escaping SearchToolsTool.SelectionFactory,
        embedder: any PooledEmbedding,
        fallback: any Tool
    ) -> any Tool {
        let fresh: [any Tool]
        do {
            fresh = try registry.makeSessionTools(selection: selection, embedder: embedder)
        } catch {
            assertionFailure("The session tools of an agent run did not build: \(error)")
            ACPAgentTelemetry.logger(.agentsComposition).error(
                "The session tools of an agent run did not build. The run gets the probe tool.",
                metadata: [
                    ACPAgentTelemetry.LogMetadataKey.toolName: "\(name)",
                    ACPAgentTelemetry.LogMetadataKey.errorType:
                        "\(ACPAgentTelemetry.errorTypeName(of: error))",
                ])
            return fallback
        }
        guard let tool = fresh.first(where: { $0.name == name }) else {
            assertionFailure("The session tools of an agent run have no tool named \(name)")
            ACPAgentTelemetry.logger(.agentsComposition).error(
                "The session tools of an agent run have no tool of this name. The run gets the probe tool.",
                metadata: [ACPAgentTelemetry.LogMetadataKey.toolName: "\(name)"])
            return fallback
        }
        return tool
    }
}

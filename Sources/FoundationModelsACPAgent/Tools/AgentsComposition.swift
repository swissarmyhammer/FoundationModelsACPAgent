import Foundation
import FoundationModels
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsSkills
import Logging

/// The mounted `agents` tool of one session. It has the tool of the root
/// session, the runner of its agent runs, and their environment.
struct AgentsMount: Sendable {
  /// The `agents` tool of the root session.
  let tool: AgentsTool

  /// The runner of the agent runs of the session. The session lifecycle stops
  /// it before the root session closes. The Router does not know the runs of
  /// a session.
  let runner: AgentRunner

  /// The environment of each agent run. It has the one skills registry and
  /// the settle period. It also has the `skills` tool of the root session and
  /// of the runs, and the tools of the runs.
  let environment: AgentEnvironment

  /// The queue that announces each run of the session to the client with a
  /// `subagent_update`. The agent binds its outlet when it mounts the root
  /// session, and the stop of the runs ends the queue.
  let announcer: SubagentAnnouncer
}

/// The composition of the standalone `agents` tool of FoundationModelsAgents
/// (task ^c4a6mwy).
///
/// **The tool is standalone, not a Multitool capability.** A `start agent` call
/// waits for its run. It waits for the settle period of the session. A run that
/// ends in that time gives its final message as the output of the call. A
/// longer run goes to the background. The session injects its final message as
/// a new message. Inside a `runCode` snippet that wait would be a second
/// background point. So the tool mounts beside `searchTools`, `runCode` and
/// `skills`, the same as the `skills` tool.
///
/// **One skills registry and one marketplace store.** The environment makes the
/// `skills` tool from the skills registry of the session. The root session
/// mounts that tool, `AgentEnvironment.skillsTool`, in place of its own. The
/// agent registry reads the marketplace layers of the same store. The host tool
/// catalog never registers `skills`: the environment adds it.
///
/// **The tools of a run.** A run gets the Multitool session tools,
/// `searchTools` and `runCode`, by name. They come from the registry of the
/// root session. It also gets the `skills` tool. The `tools` and
/// `disallowedTools` keys of an agent select from these names.
///
/// The `FoundationModelsAgents::` module selector names the tool catalog of
/// FoundationModelsAgents. This module has a ``ToolCatalog`` of its own.
/// FoundationModelsAgents has an enum with the name of its module. So
/// `FoundationModelsAgents.ToolCatalog` does not name the type.
enum AgentsComposition {
  /// Builds the agent registry, the environment, the runner and the
  /// `agents` tool. The `agents` tool is always on, thus each composed
  /// session has this mount.
  ///
  /// The agent registry reads the agent folders `<id>/AGENT.md` and
  /// `agents/<id>/AGENT.md` of each layer of the `agents` dotfolder stack
  /// (``ToolCatalog/agentsDotfolderName``). It also reads the agent folders
  /// `agents/<id>/AGENT.md` of each marketplace layer of the skills store
  /// (see ``makeAgentRegistry(context:marketplaces:)``). It does not watch.
  /// The schema of the tool is fixed when the tool is made. So an agent that
  /// a later edit adds reaches the next session.
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
  ///     (``makeRunEventObserver(runCallJoins:announcer:)``).
  ///     The environment also gets the links of ``CatalogContext/agentRunHost``: the
  ///     recording root of the runs, the mark of an ended run, the mail to a caller that is
  ///     not a run, and the completion of a claimed call. With them a run marks its session
  ///     as ended, and a later process restores a run that did not end.
  /// - Returns: The mount.
  /// - Throws: Whatever `AgentRegistry.load()`, `AgentEnvironment.make`
  ///   or `AgentsTool.make(context:)` throws.
  static func compose(
    context: CatalogContext, skills: SkillsSource, runTools: FoundationModelsAgents::ToolCatalog,
    runCallJoins: RunCallJoinTable
  ) async throws -> AgentsMount {
    let registry = makeAgentRegistry(context: context, marketplaces: skills.marketplaces)
    try await registry.load()
    let announcer = SubagentAnnouncer(holds: runCallJoins.holds)
    let made = try await AgentEnvironment.make(
      profile: context.profile,
      skills: skills.registry,
      skillsSelectionModel: RoutedSelectionModel(profile: context.profile),
      workingDirectory: context.workingDirectory,
      tools: runTools,
      inlineSettleGrace: context.inlineSettleGrace,
      runEventObserver: makeRunEventObserver(runCallJoins: runCallJoins, announcer: announcer),
      callerMail: context.agentRunHost?.callerMail)
    let environment = context.agentRunHost?.linking(made) ?? made
    let runner = AgentRunner(registry: registry, environment: environment)
    // The scheduled agents of each session are saved beside its recording,
    // so a restart or a resume restores them. Runs that cannot restore (no
    // host) keep their tasks in memory only.
    if let recordingRoot = context.agentRunHost?.recordingRoot {
      await runner.useScheduleStore(ScheduleFileStore(recordingRoot: recordingRoot))
    }
    let tool = try await AgentsTool.make(context: AgentsToolContext(runner: runner))
    bindHolds(of: runCallJoins, tool: tool, runner: runner, announcer: announcer)
    return AgentsMount(tool: tool, runner: runner, environment: environment, announcer: announcer)
  }

  /// Tells the holds of the surface which tool starts a child, and how to find the run of a call.
  /// A call can return before its run gave an event. Then the holds ask the runner for the run
  /// with the token of the call. The announcer adopts the run, so the final status of the call
  /// waits for the end of the child.
  ///
  /// - Parameters:
  ///   - runCallJoins: The join table of the session, which holds the holds.
  ///   - tool: The `agents` tool.
  ///   - runner: The runner of the runs.
  ///   - announcer: The announcer of the runs.
  private static func bindHolds(
    of runCallJoins: RunCallJoinTable, tool: AgentsTool, runner: AgentRunner,
    announcer: SubagentAnnouncer
  ) {
    // The closure holds the runner and the announcer weakly. The runner holds the join table
    // through its tool factories and its run observer, and the join table holds this closure. A
    // strong hold would make a reference cycle: the runner would never go away, and its search over
    // the agents would keep the embedder and the models of the profile in the model pool.
    runCallJoins.holds.bind(toolName: tool.name) { [weak runner, weak announcer] token in
      guard let runner, let announcer else { return }
      let wanted = token.uppercased()
      if let run = await runner.runs.first(where: { $0.completionToken?.uppercased() == wanted }) {
        announcer.observe(run)
      }
    }
  }

  /// Makes the observer of the session events of each agent run of the session (task ^zbcrex8).
  /// It gives each event to `runCallJoins`. The open record of a tool run then writes "no join"
  /// for that run (``RunCallJoinTable/recordAgentRunEvent(_:)``). It also gives the run and the
  /// event to `announcer`. The announcer queues the `subagent_update` of the run before any
  /// message that uses the id of the child. It also keeps the events for the projector of the
  /// child session (``SubagentAnnouncer/observe(_:output:)``). The observer sends nothing
  /// itself, so each event of a child goes to the wire once, through its own projector.
  ///
  /// An agent run uses the shell capability of the root session. The output of its shell runs
  /// comes on the shell output stream of the session. Its tool records go to the event stream of
  /// the agent run. The terminal stream holds a shell run that has no entry. This entry releases
  /// the run while the agent run continues.
  ///
  /// The environment is made for one session, and the table belongs to the same surface. So the
  /// observer needs no lookup from the run to the session. Each run calls the observer
  /// synchronously in its follow loop, child runs too. Two runs can call it at the same time.
  /// Thus the observer only takes the lock of the table and the lock of the announcer. It does
  /// not wait.
  ///
  /// - Parameters:
  ///   - runCallJoins: The join table of the session.
  ///   - announcer: The announcer of the session.
  /// - Returns: The observer for `AgentEnvironment.make(runEventObserver:)`.
  static func makeRunEventObserver(
    runCallJoins: RunCallJoinTable, announcer: SubagentAnnouncer
  ) -> AgentEnvironment.RunEventObserver {
    { run, output in
      runCallJoins.recordAgentRunEvent(output)
      announcer.observe(run, output: output)
    }
  }

  /// Makes the agent registry over the `agents` dotfolder stack, and over the
  /// marketplace store when the session has one. The registry reads no file until
  /// `load()`. The stack is the ``SettingsFolders/Kind/agents`` stack of
  /// ``CatalogContext/settingsFolders``. Its user layer is the synced root of a custom
  /// home. For an XDG home, it is `$XDG_CONFIG_HOME/agents` (``AgentHome``). The
  /// project layer is `<cwd>/.agents/`, never the working directory itself. It reads
  /// `AGENTS_DEFAULTS_DIR` from the environment of the settings folders.
  ///
  /// Each local layer holds the agent folders `<id>/AGENT.md` and
  /// `agents/<id>/AGENT.md`; in one layer the `<id>/` copy wins. The root
  /// `AGENT.md` of a layer is the default agent. A child folder whose name is
  /// not a valid agent id is not an agent. It gives no diagnostic. So the
  /// settings folders `_skills/` and `_rules/` of the root are not agents.
  ///
  /// - Parameters:
  ///   - context: The session whose working directory roots the project layer
  ///     of the stack. Its settings folders give the defaults layer and the
  ///     user layer of the stack.
  ///   - marketplaces: The started skills marketplace store, or `nil`.
  /// - Returns: The registry.
  static func makeAgentRegistry(
    context: CatalogContext, marketplaces: MarketplaceStore?
  ) -> AgentRegistry {
    let stack = context.settingsFolders.stack(
      for: .agents, workingDirectory: context.workingDirectory)
    let templateContext = ToolCatalog.skillsTemplateContext(context.configuration.tools)
    guard let marketplaces else {
      return AgentRegistry(stack: stack, templateContext: templateContext)
    }
    return AgentRegistry(
      marketplaces: marketplaces, stack: stack, templateContext: templateContext)
  }

  /// Makes the tool catalog of the runs. It has one factory for each
  /// Multitool session tool of the root session, by its name.
  ///
  /// Each factory call makes a new pair of session tools over `registry`. So
  /// each run gets its own `searchTools` and `runCode`. The call gives the
  /// tool of the name. A `searchTools` and a `runCode` of one run come from
  /// two pairs. Both read the same registry. A registry holder keeps no state
  /// of a search. So the two answer as one pair does. The pair that the
  /// session mounted proves that the call succeeds for this registry, and it
  /// gives the names and the fallback tools. The call makes no pair of its
  /// own, because each pair builds the search index of the registry, and that
  /// is the largest cost of a new session. A later call over the same
  /// registry and the same selection gives the same result. A later call
  /// that fails is a defect, and
  /// ``freshSessionTool(named:registry:selection:embedder:fallback:)``
  /// records it.
  ///
  /// - Parameters:
  ///   - registry: The built Multitool registry of the root session.
  ///   - selection: The selection tier of `searchTools`.
  ///   - embedder: The embedder that `searchTools` and `runCode` rank with.
  ///   - mounted: The pair of session tools that the session mounted from
  ///     `registry` with the same `selection` and `embedder`.
  /// - Returns: The tool catalog of the runs.
  static func makeRunTools(
    registry: MultiTool.Registry,
    selection: @escaping SearchToolsTool.SelectionFactory,
    embedder: any PooledEmbedding,
    mounted: [any Tool]
  ) -> FoundationModelsAgents::ToolCatalog {
    var tools = FoundationModelsAgents::ToolCatalog()
    for probe in mounted {
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
  /// The mounted pair of ``makeRunTools(registry:selection:embedder:mounted:)`` proves
  /// that the call succeeds for this registry and gives a tool of this name.
  /// Thus a failure here is unexpected. A debug build stops at the assertion.
  /// A release build logs the failure and gives `fallback`, the tool of the
  /// mounted pair. The tool catalog of a run takes a factory that cannot throw.
  ///
  /// - Parameters:
  ///   - name: The name of the session tool, `searchTools` or `runCode`.
  ///   - registry: The built Multitool registry of the root session.
  ///   - selection: The selection tier of `searchTools`.
  ///   - embedder: The embedder that `searchTools` and `runCode` rank with.
  ///   - fallback: The tool of the same name from the mounted pair.
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

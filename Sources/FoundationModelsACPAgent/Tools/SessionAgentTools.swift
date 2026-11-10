import FoundationModels
import FoundationModelsAgents
import FoundationModelsMultitool
import FoundationModelsRouter
import Synchronization

/// The `tools:` and `disallowedTools:` keys of the session agent over the
/// tool names of one root session (ACPA-1b, D90 (c)).
///
/// The selection uses `AgentDefinition.toolSelection(over:hasAgentsTool:)`,
/// the match that a run of FoundationModelsAgents uses, thus a root session
/// and a run read one list the same way. A root session always has the
/// `agents` tool, thus the names do not hold `agents`: the selection gives it
/// through its flag, and a plain `agents` entry gives the grant.
///
/// The tools in ``ToolCatalog/alwaysOnToolNames`` always stay. When the agent
/// names one of them in `disallowedTools:`, or leaves it out of `tools:`, the
/// selection keeps it and gives one warning that names each such tool.
struct SessionToolSelection: Sendable, Equatable {
  /// The names that the session keeps: the names that the agent selected,
  /// and each always-on name of the session.
  let keptNames: Set<String>

  /// The grant of the `agents` tool, or `nil` when the agent gives no grant.
  /// With `nil`, the `agents` tool can start each agent.
  let agentsGrant: AgentsGrant?

  /// The warnings for the log: one for each diagnostic of the selection,
  /// then one that names the always-on tools that the agent tried to remove.
  let warnings: [String]

  /// Applies the keys of `definition` to `names`.
  ///
  /// - Parameters:
  ///   - definition: The session agent.
  ///   - names: The tool names of the session, with no `agents`. An MCP tool
  ///     is `mcp__<server>__<tool>`.
  init(definition: AgentDefinition, names: [String]) {
    let selection = definition.toolSelection(over: names, hasAgentsTool: true)
    let selected = Set(selection.names)
    let alwaysOn = Set(names).intersection(ToolCatalog.alwaysOnToolNames)
    let removesAgents =
      selection.deniesAgents || (definition.tools != nil && selection.agentsGrant == nil)
    let kept = alwaysOn.subtracting(selected).sorted()
      + (removesAgents ? [ToolCatalog.agentsToolName] : [])
    keptNames = selected.union(alwaysOn)
    agentsGrant = selection.agentsGrant
    warnings =
      selection.diagnostics.map { "\($0)" }
      + (kept.isEmpty ? [] : [Self.keptWarning(agent: definition.id, kept: kept)])
  }

  /// The skills template groups of a root session with the keys of
  /// `definition` applied (``ToolCatalog/skillsTemplateContext(_:mode:sessionAgent:)``).
  ///
  /// The selection reads each group name as a tool name, the match that
  /// ``SessionSurface/applying(agent:)`` uses. Thus a group that the agent
  /// removes is `false`, and the groups in ``ToolCatalog/alwaysOnToolNames``
  /// and the `agents` group keep their values. The `mcp` group reads one
  /// probe name `mcp__<server>__` for each configured server, or the probe
  /// `mcp__` when the configuration names no server. It stays `true` when
  /// the selection keeps one probe. A selection never turns a group on.
  ///
  /// - Parameters:
  ///   - groups: The value of each group from the configuration and the
  ///     tool mode, by its name.
  ///   - definition: The session agent.
  ///   - mcpServerNames: The names of the configured MCP servers.
  /// - Returns: The value of each group, by its name.
  static func templateGroups(
    _ groups: [String: Bool], of definition: AgentDefinition, mcpServerNames: [String]
  ) -> [String: Bool] {
    let mcpProbes =
      mcpServerNames.isEmpty
      ? [RegistrySelection.mcpPrefix]
      : mcpServerNames.map { server in
        RegistrySelection.mcpPrefix + server + RegistrySelection.mcpSeparator
      }
    let toolNames = groups.keys.filter {
      $0 != ToolCatalog.agentsToolName && $0 != ToolCatalog.mcpGroupName
    }
    let kept = SessionToolSelection(definition: definition, names: toolNames + mcpProbes).keptNames
    return Dictionary(
      uniqueKeysWithValues: groups.map { name, isOn in
        switch name {
        case ToolCatalog.agentsToolName:
          (name, isOn)
        case ToolCatalog.mcpGroupName:
          (name, isOn && !kept.isDisjoint(with: mcpProbes))
        default:
          (name, isOn && kept.contains(name))
        }
      })
  }

  /// The warning for the always-on tools that the agent tried to remove.
  ///
  /// - Parameters:
  ///   - agent: The id of the session agent.
  ///   - kept: The names of the tools that stay.
  /// - Returns: The warning text.
  private static func keptWarning(agent: String, kept: [String]) -> String {
    "The session agent `\(agent)` cannot remove a tool that gives an endpoint (D90). "
      + "These tools stay: \(kept.map { "`\($0)`" }.joined(separator: ", "))."
  }
}

/// The selection of the session agent over one Multitool registry: the
/// filter that the registry of the root `runCode` gets.
///
/// The filter runs the selection again on each registry, because an MCP
/// refresh can add or remove a tool, and an entry such as `mcp__srv` then
/// selects the new tools of that server.
struct RegistrySelection: Sendable {
  /// The session agent.
  let definition: AgentDefinition

  /// The names of the top-level tools of the session, with no `agents`.
  /// They complete the names of the selection, so an entry that names a
  /// top-level tool gives no warning.
  let topLevelNames: [String]

  /// The names of the MCP servers of the session: the nouns of their tools
  /// in the registry.
  let mcpServerNames: Set<String>

  /// The registry with only the entries that the session agent keeps. The
  /// GraphQL endpoints stay those of `registry`: the endpoint list of the
  /// client does not follow the tools of the model (D90 (c)).
  ///
  /// - Parameter registry: The full registry.
  /// - Returns: The filtered registry.
  func applied(to registry: MultiTool.Registry) -> MultiTool.Registry {
    let kept = SessionToolSelection(
      definition: definition, names: topLevelNames + capabilityNames(of: registry)
    ).keptNames
    let entries = registry.surface.entries.filter { kept.contains(capabilityName(of: $0)) }
    let paths = Set(entries.map(\.path))
    return MultiTool.Registry(
      surface: APISurface(entries: entries),
      tools: registry.tools.filter { paths.contains($0.key) },
      isDirectMode: registry.isDirectMode,
      graphQLEndpoints: registry.graphQLEndpoints)
  }

  /// The distinct capability names of the entries of `registry`.
  ///
  /// - Parameter registry: The registry.
  /// - Returns: The names, in sorted order.
  func capabilityNames(of registry: MultiTool.Registry) -> [String] {
    Set(registry.surface.entries.map(capabilityName(of:))).sorted()
  }

  /// The name of the capability of one entry: `mcp__<server>__<tool>` for a
  /// tool of an MCP server, the noun of a grouped entry, or the path of a
  /// standalone entry.
  ///
  /// - Parameter entry: The entry of the registry.
  /// - Returns: The name.
  func capabilityName(of entry: APISurface.Entry) -> String {
    guard let group = entry.group else {
      return entry.path
    }
    guard mcpServerNames.contains(group) else {
      return group
    }
    return "\(Self.mcpPrefix)\(group)\(Self.mcpSeparator)\(entry.descriptor.name)"
  }

  /// The start of the name of an MCP tool in the selection.
  static let mcpPrefix = "mcp__"

  /// The text between the server and the tool in the name of an MCP tool.
  static let mcpSeparator = "__"
}

/// The staging of the root `runCode` of a session: it applies the selection
/// of the session agent to each registry that it stages.
///
/// The surface refresher of the MCP servers stages each rebuilt registry
/// here, thus a refresh keeps the selection. Before ``select(_:current:)``,
/// a registry passes with no change: the agent of the session is not known
/// when the refresher starts.
final class SessionRegistryStaging: RegistryStaging {
  /// What the lock guards.
  private struct State: Sendable {
    /// The selection, or `nil` before the agent of the session is known.
    var selection: RegistrySelection?

    /// The newest full registry that a caller staged, or `nil` when none.
    var newest: MultiTool.Registry?
  }

  /// The staging of the mounted `runCode`.
  private let inner: any RegistryStaging

  /// The guarded state.
  private let state = Mutex(State())

  /// Makes a staging over the staging of the mounted `runCode`.
  ///
  /// - Parameter inner: The staging of the mounted `runCode`.
  init(wrapping inner: any RegistryStaging) {
    self.inner = inner
  }

  /// Sets the selection, and stages the filtered form of the newest full
  /// registry: the registry that a refresh staged last, else `current`.
  ///
  /// - Parameters:
  ///   - selection: The selection of the session agent.
  ///   - current: The registry that the mounted `runCode` reads now.
  func select(_ selection: RegistrySelection, current: MultiTool.Registry) {
    let base = state.withLock { state in
      state.selection = selection
      return state.newest ?? current
    }
    inner.stage(selection.applied(to: base))
  }

  /// Stages `registry`, filtered by the selection when there is one.
  ///
  /// - Parameter registry: The full registry.
  func stage(_ registry: MultiTool.Registry) {
    let selection = state.withLock { state in
      state.newest = registry
      return state.selection
    }
    inner.stage(selection?.applied(to: registry) ?? registry)
  }
}

extension SessionSurface {
  /// This surface with the `tools:` and `disallowedTools:` keys of the
  /// session agent applied (ACPA-1b).
  ///
  /// The registry of the root `runCode` keeps only the selected
  /// capabilities, the top-level tools keep only the selected tools, and a
  /// grant `Agent(a, b)` makes a root `agents` tool that can start only
  /// those agents. The tools in ``ToolCatalog/alwaysOnToolNames`` always
  /// stay. Each warning of the selection goes to the log. The agent runs
  /// keep the tools of the full registry.
  ///
  /// - Parameter definition: The session agent, or `nil` for the builtin
  ///   floor, which keeps the full surface.
  /// - Returns: The surface of the session.
  /// - Throws: The error of `AgentsTool.make(context:)` for a grant.
  func applying(agent definition: AgentDefinition?) async throws -> SessionSurface {
    guard let definition, let agents else {
      return self
    }
    let agentsName = agents.tool.name
    let runCode = tools.lazy.compactMap { $0 as? MultiTool }.first
    let registrySelection = RegistrySelection(
      definition: definition, topLevelNames: tools.map(\.name).filter { $0 != agentsName },
      mcpServerNames: await mcpServerNames())
    let registryNames = runCode.map { registrySelection.capabilityNames(of: $0.currentRegistry) }
    let selection = SessionToolSelection(
      definition: definition, names: registrySelection.topLevelNames + (registryNames ?? []))
    for warning in selection.warnings {
      ACPAgentTelemetry.logger(.session).warning("\(warning)")
    }
    if let runCode, let registryStaging {
      registryStaging.select(registrySelection, current: runCode.currentRegistry)
      await runCode.submissionWillBegin()
    }
    let mount = try await agents.granting(selection.agentsGrant)
    let kept = tools.filter { $0.name == agentsName || selection.keptNames.contains($0.name) }
    return replacing(
      tools: kept.map { $0.name == agentsName ? mount.tool : $0 }, agents: mount)
  }

  /// The names of the MCP servers of this surface: the nouns of their tools
  /// in the registry. `Array.map` cannot wait, and the name is a property of
  /// the server actor, thus a loop reads each one.
  ///
  /// - Returns: The names.
  private func mcpServerNames() async -> Set<String> {
    var names: Set<String> = []
    for server in mcpServers {
      names.insert(await server.name)
    }
    return names
  }
}

extension AgentsMount {
  /// This mount with a root `agents` tool for `grant`.
  ///
  /// - Parameter grant: The grant of the session agent, or `nil` for none.
  /// - Returns: This mount for `nil` and `.all`. For `.only`, a mount whose
  ///   tool can start only the named agents.
  /// - Throws: The error of `AgentsTool.make(context:)`.
  func granting(_ grant: AgentsGrant?) async throws -> AgentsMount {
    guard let allowedNames = grant?.allowedNames else {
      return self
    }
    return AgentsMount(
      tool: try await AgentsTool.make(
        context: AgentsToolContext(runner: runner, allowedNames: allowedNames)),
      runner: runner, environment: environment, announcer: announcer)
  }
}

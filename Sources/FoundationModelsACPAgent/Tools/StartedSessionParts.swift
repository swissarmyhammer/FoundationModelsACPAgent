import FoundationModelsAgents
import FoundationModelsMultitool
import FoundationModelsSkills

/// The parts that a session composition started and still owns, which
/// ``stop()`` stops (task ^2zm9hbk).
///
/// `RoutedACPAgent.composeSession`, ``ToolCatalog/sessionSurface(context:skills:agentRegistry:)``
/// and ``ToolCatalog/makeRegistry(context:)`` add each part when they start
/// it (tasks ^2zm9hbk and ^0rma59k). A step that throws before the surface
/// owns the parts then stops them, and the caller gets the error of the
/// step. ``SessionSurface/shutdown()`` stops the parts of a surface with the
/// same ``stop()``.
///
/// Each part is optional: a composition adds only the parts that it started
/// itself. A part that the caller gave stays with the caller.
struct StartedSessionParts: Sendable {
  /// The `agents` mount whose runs ``stop()`` stops: the announcer and the
  /// runner. Its registry, skills registry and marketplaces are separate
  /// parts, because the caller of a composition can own them.
  var agentRuns: AgentsMount? = nil

  /// The watched agent registry.
  var agentRegistry: AgentRegistry? = nil

  /// The watched skills registry.
  var skillsRegistry: SkillsRegistry? = nil

  /// The marketplace layers of the skills store.
  var marketplaces: SessionMarketplaces? = nil

  /// The lease of the code-context manager of the working directory.
  var codeContextLease: CodeContextLease? = nil

  /// The lease of the shell store of the working directory.
  var shellStoreLease: ShellStoreLease? = nil

  /// The MCP server pool: the servers, their subprocesses and the refresher.
  var serverPool: MCPServerPool? = nil

  /// Adds the parts that the build of the registry took: the leases and the
  /// server pool.
  ///
  /// - Parameter built: The built registry.
  mutating func add(_ built: ToolCatalog.BuiltRegistry) {
    codeContextLease = built.codeContextLease
    shellStoreLease = built.shellStoreLease
    serverPool = built.pool
  }

  /// Adds the skills registry and the marketplace layers of `skills`.
  ///
  /// - Parameter skills: The skills source.
  mutating func add(_ skills: SkillsSource) {
    skillsRegistry = skills.registry
    marketplaces = skills.marketplaces
  }

  /// Stops each part: first the agent runs, then the watches of the
  /// registries and the marketplace layers, then the leases and the server
  /// pool. A stop of a registry or of the marketplace layers that already
  /// stopped does nothing. A lease is released one time for each call, thus
  /// a composition calls ``stop()`` one time.
  func stop() async {
    await agentRuns?.announcer.stop()
    await agentRuns?.runner.stop()
    await agentRegistry?.stopWatching()
    await skillsRegistry?.stopWatching()
    await marketplaces?.stop()
    await codeContextLease?.release()
    await shellStoreLease?.release()
    await serverPool?.shutdownAll()
  }
}

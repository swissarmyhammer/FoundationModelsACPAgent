import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import Synchronization
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsAgents
@testable import FoundationModelsRouter

/// The tool catalog of this host. FoundationModelsAgents has a `ToolCatalog` of its own.
private typealias SurfaceCatalog = FoundationModelsACPAgent.ToolCatalog

/// The `tools:` and `disallowedTools:` keys of the agent of a run filter the
/// registry of the `runCode` of that run (task ^2dyhd2t). The filter is the
/// rule of the root session (``RegistrySelection``): the endpoint nouns stay,
/// and each other noun stays only when the keys keep it.
///
/// The unit tests resolve the run tools with the resolver of
/// FoundationModelsAgents, the step that a new run and a restored run both
/// use. The restore test resumes a recorded chain and reads the `runCode` of
/// the restored child.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct RunToolSelectionTests {
  /// The prefix of the folders of each test of this suite.
  private static let label = "RunToolSelectionTests"

  /// The noun of the shell capability in the registry.
  private static let shellNoun = "shell"

  /// The noun of the web capability in the registry.
  private static let webNoun = "web"

  /// The `tools:` key that keeps only the web capability.
  private static let webOnlyKey = "tools: [web]"

  /// The resolved tools of one run.
  private struct ResolvedRun {
    /// The nouns of the registry of the `runCode` of the run.
    let nouns: Set<String>

    /// The diagnostics of the resolve.
    let diagnostics: [AgentDiagnostic]
  }

  /// The nouns of the registry of the `runCode` in `tools`.
  ///
  /// - Parameter tools: The tools of a run.
  /// - Returns: The nouns.
  /// - Throws: An issue when `tools` holds no `runCode`.
  private static func runCodeNouns(in tools: [any Tool]) throws -> Set<String> {
    let first = tools.lazy.compactMap { $0 as? MultiTool }.first
    let runCode = try #require(first, "the run has no runCode")
    return Set(runCode.currentRegistry.surface.entries.compactMap(\.group))
  }

  /// The registry of a fresh session, and the pair of session tools that the
  /// session mounts from it.
  private struct MountedRegistry {
    /// The built Multitool registry of the session.
    let registry: MultiTool.Registry

    /// The selection tier of `searchTools`.
    let selection: SearchToolsTool.SelectionFactory

    /// The embedder that `searchTools` and `runCode` rank with.
    let embedder: FoundationModelsACPAgent.ProfileEmbedding

    /// The pair of session tools that the session mounts from `registry`.
    let mounted: [any Tool]
  }

  /// Builds the registry of a fresh session, and mounts its pair of session
  /// tools, as a root session does.
  ///
  /// - Parameter name: The name of the test, for the folders.
  /// - Returns: The registry and the mounted pair.
  /// - Throws: What the context, the registry build or the mount throws.
  private static func mountedRegistry(name: String) async throws -> MountedRegistry {
    let context = try await AgentsToolTests.makeContext(label: "\(label)-\(name)")
    let built = try await SurfaceCatalog.makeRegistry(context: context)
    let selection = SurfaceCatalog.makeSearchSelection(profile: context.profile)
    let embedder = ProfileEmbedding(embedder: context.profile.embedding)
    let mounted = try built.registry.makeSessionTools(selection: selection, embedder: embedder)
    return MountedRegistry(
      registry: built.registry, selection: selection, embedder: embedder, mounted: mounted)
  }

  /// Resolves the tools of a run of an agent with the frontmatter `keys`
  /// over the run catalog of a fresh session registry.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the agent of the run.
  ///   - name: The name of the test, for the folders.
  /// - Returns: The nouns of the `runCode` of the run, and the diagnostics.
  /// - Throws: What the registry build or the resolve throws, or an issue
  ///   when the run has no `runCode`.
  private static func resolvedRun(keys: [String], name: String) async throws -> ResolvedRun {
    let session = try await mountedRegistry(name: name)
    let runTools = AgentsComposition.makeRunTools(
      registry: session.registry, mcpServerNames: [], selection: session.selection,
      embedder: session.embedder, mounted: session.mounted)
    let definition = try SessionAgentToolsTests.definition(keys: keys)
    let resolved = try await ToolResolver(agent: definition.id, provenance: definition.provenance)
      .resolve(definition, catalog: runTools, agentsTool: nil)
    return ResolvedRun(
      nouns: try runCodeNouns(in: resolved.tools), diagnostics: resolved.diagnostics)
  }

  /// The `disallowedTools:` key that denies the `skills` tool.
  private static let noSkillsKey = "disallowedTools: [\(SkillOutputProtection.skillsToolName)]"

  /// The `tools:` key that keeps the web capability and grants the `agents`
  /// tool.
  private static let webAndAgentsKey = "tools: [web, agents]"

  /// The resolved tools of one run over the run catalog of the agent
  /// environment of a session: the catalog that a real run reads.
  private struct EnvironmentRun {
    /// The names of the resolved tools.
    let toolNames: [String]

    /// The nouns of the registry of the `runCode` of the run.
    let nouns: Set<String>

    /// The diagnostics of the resolve.
    let diagnostics: [AgentDiagnostic]

    /// The grant that the resolve gave the `agents` tool factory, or `nil`.
    let agentsGrant: AgentsGrant?
  }

  /// The grant that the `agents` tool factory of one resolve gets.
  private final class GrantRecord: Sendable {
    /// The recorded grant, or `nil` when the factory got none.
    let grant = Mutex<AgentsGrant?>(nil)
  }

  /// Resolves the tools of a run of an agent with the frontmatter `keys`
  /// over the run catalog of the agent environment of a new session. The
  /// catalog holds the `skills` tool, and the resolve has an `agents` tool
  /// factory, as a real run has.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the agent of the run.
  ///   - name: The name of the test, for the folders.
  /// - Returns: The resolved run.
  /// - Throws: What the surface build or the resolve throws, or an issue
  ///   when the run has no `runCode`.
  private static func environmentRun(keys: [String], name: String) async throws -> EnvironmentRun {
    let context = try await AgentsToolTests.makeContext(label: "\(label)-\(name)")
    let surface = try await SurfaceCatalog.sessionSurface(context: context)
    let agents = try #require(surface.agents, "the surface has no agents mount")
    let definition = try SessionAgentToolsTests.definition(keys: keys)
    let record = GrantRecord()
    let resolved = try await ToolResolver(agent: definition.id, provenance: definition.provenance)
      .resolve(definition, catalog: agents.environment.tools) { grant in
        record.grant.withLock { $0 = grant }
        return nil
      }
    await surface.shutdown()
    return EnvironmentRun(
      toolNames: resolved.tools.map(\.name), nouns: try runCodeNouns(in: resolved.tools),
      diagnostics: resolved.diagnostics, agentsGrant: record.grant.withLock { $0 })
  }

  /// The diagnostics of the rule that the `runCode` of a run applies to the
  /// registry for an agent with the frontmatter `keys`
  /// (``AgentsComposition/runRegistrySelection(of:mountedNames:mcpServerNames:)``).
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the agent of the run.
  ///   - name: The name of the test, for the folders.
  /// - Returns: The diagnostics.
  /// - Throws: What the registry build throws.
  private static func runRuleDiagnostics(
    keys: [String], name: String
  ) async throws -> [AgentDiagnostic] {
    let session = try await mountedRegistry(name: name)
    let definition = try SessionAgentToolsTests.definition(keys: keys)
    let rule = AgentsComposition.runRegistrySelection(
      of: definition, mountedNames: session.mounted.map(\.name), mcpServerNames: [])
    return definition.toolSelection(
      over: rule.selectionNames(of: session.registry), hasAgentsTool: true
    ).diagnostics
  }

  // MARK: - A new run

  /// A run of an agent with `disallowedTools: [shell]` has no shell noun in
  /// its `runCode`.
  @Test func aRunWithDisallowedShellHasNoShellInRunCode() async throws {
    let run = try await Self.resolvedRun(keys: ["disallowedTools: [shell]"], name: "no-shell")

    #expect(!run.nouns.contains(Self.shellNoun), "\(run.nouns)")
  }

  /// A run of an agent with no `tools:` key keeps the shell noun in its
  /// `runCode`.
  @Test func aRunWithNoToolsKeyKeepsTheShellInRunCode() async throws {
    let run = try await Self.resolvedRun(keys: [], name: "plain")

    #expect(run.nouns.contains(Self.shellNoun), "\(run.nouns)")
  }

  /// A run of an agent with `tools: [web]` has the web noun in its
  /// `runCode`.
  @Test func aRunWithToolsWebHasTheWebInRunCode() async throws {
    let run = try await Self.resolvedRun(keys: [Self.webOnlyKey], name: "web-on")

    #expect(run.nouns.contains(Self.webNoun), "\(run.nouns)")
  }

  /// A run of an agent with `tools: [web]` keeps the files noun in its
  /// `runCode`: `files` gives an endpoint, thus the keys cannot remove it.
  @Test func aRunWithToolsWebKeepsTheFilesInRunCode() async throws {
    let run = try await Self.resolvedRun(keys: [Self.webOnlyKey], name: "web-files")

    #expect(run.nouns.contains(SurfaceCatalog.filesGroupName), "\(run.nouns)")
  }

  /// A run of an agent with `tools: [web]` has no shell noun in its
  /// `runCode`.
  @Test func aRunWithToolsWebHasNoShellInRunCode() async throws {
    let run = try await Self.resolvedRun(keys: [Self.webOnlyKey], name: "web-no-shell")

    #expect(!run.nouns.contains(Self.shellNoun), "\(run.nouns)")
  }

  /// A run of an agent with `tools: [web]` gives no unknown-tool warning:
  /// `web` is a capability name of the kept `runCode`.
  @Test func aRunWithToolsWebGivesNoUnknownToolWarning() async throws {
    let run = try await Self.resolvedRun(keys: [Self.webOnlyKey], name: "web-warning")

    #expect(!run.diagnostics.contains { $0.code == .unknownTool }, "\(run.diagnostics)")
  }

  // MARK: - The skills and agents names

  /// A run of an agent with `disallowedTools: [skills]` gives no
  /// unknown-tool warning: `skills` is a tool of the run catalog.
  @Test func aRunWithDisallowedSkillsGivesNoUnknownToolWarning() async throws {
    let run = try await Self.environmentRun(keys: [Self.noSkillsKey], name: "no-skills-warning")

    #expect(!run.diagnostics.contains { $0.code == .unknownTool }, "\(run.diagnostics)")
  }

  /// A run of an agent with `disallowedTools: [skills]` has no `skills`
  /// tool: the resolve of the run removes a plain catalog tool.
  @Test func aRunWithDisallowedSkillsHasNoSkillsTool() async throws {
    let run = try await Self.environmentRun(keys: [Self.noSkillsKey], name: "no-skills-tool")

    #expect(!run.toolNames.contains(SkillOutputProtection.skillsToolName), "\(run.toolNames)")
  }

  /// A run of an agent with `disallowedTools: [skills]` keeps the shell
  /// noun in its `runCode`.
  @Test func aRunWithDisallowedSkillsKeepsTheShellInRunCode() async throws {
    let run = try await Self.environmentRun(keys: [Self.noSkillsKey], name: "no-skills-shell")

    #expect(run.nouns.contains(Self.shellNoun), "\(run.nouns)")
  }

  /// The rule of the `runCode` of a run knows the name `skills`, as the
  /// rule of the root session does: `disallowedTools: [skills]` gives no
  /// unknown-tool warning in that rule.
  @Test func theRunCodeRuleKnowsTheSkillsName() async throws {
    let diagnostics = try await Self.runRuleDiagnostics(
      keys: [Self.noSkillsKey], name: "rule-skills")

    #expect(!diagnostics.contains { $0.code == .unknownTool }, "\(diagnostics)")
  }

  /// A run of an agent with `tools: [web, agents]` gives no unknown-tool
  /// warning: `agents` names the `agents` tool of the run.
  @Test func aRunWithToolsWebAndAgentsGivesNoUnknownToolWarning() async throws {
    let run = try await Self.environmentRun(keys: [Self.webAndAgentsKey], name: "agents-warning")

    #expect(!run.diagnostics.contains { $0.code == .unknownTool }, "\(run.diagnostics)")
  }

  /// A run of an agent with `tools: [web, agents]` grants its `agents` tool
  /// each agent.
  @Test func aRunWithToolsWebAndAgentsGrantsEachAgent() async throws {
    let run = try await Self.environmentRun(keys: [Self.webAndAgentsKey], name: "agents-grant")

    #expect(run.agentsGrant == .all)
  }

  /// A run of an agent with `tools: [web, agents]` has the web noun and no
  /// shell noun in its `runCode`.
  @Test func aRunWithToolsWebAndAgentsHasOnlyTheWebOfTheTwo() async throws {
    let run = try await Self.environmentRun(keys: [Self.webAndAgentsKey], name: "agents-nouns")

    #expect(
      run.nouns.intersection([Self.webNoun, Self.shellNoun]) == [Self.webNoun], "\(run.nouns)")
  }

  /// The rule of the `runCode` of a run knows the name `agents`, as the
  /// rule of the root session does: `tools: [web, agents]` gives no
  /// unknown-tool warning in that rule.
  @Test func theRunCodeRuleKnowsTheAgentsName() async throws {
    let diagnostics = try await Self.runRuleDiagnostics(
      keys: [Self.webAndAgentsKey], name: "rule-agents")

    #expect(!diagnostics.contains { $0.code == .unknownTool }, "\(diagnostics)")
  }

  // MARK: - A restored run

  /// A restored run of an agent with `tools: [agents, web]` has no shell
  /// noun in its `runCode`. The definition changes between the record and
  /// the resume, so the tools come from the restore. The `agents` entry
  /// keeps the tool that the child used to start its own child.
  @Test func aRestoredRunWithToolsWebHasNoShellInRunCode() async throws {
    let recording = try await ResumeNestedSessionsTests.recordShutDownChain()
    try AgentsToolTests.writeAgent(
      named: ResumeNestedSessionsTests.childAgent, in: recording.cwd, tools: "[agents, web]")
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-restored", workingDirectory: recording.cwd)
    try await ResumeNestedSessionsTests.resumeRoot(of: recording, on: fixture)
    let child = try #require(await fixture.harness.agent.sessions[recording.child])
    let actor = try #require(child.session as? RoutedSessionActor)

    let nouns = try Self.runCodeNouns(in: actor.originalTools)

    #expect(!nouns.contains(Self.shellNoun), "\(nouns)")
    await fixture.close()
  }
}

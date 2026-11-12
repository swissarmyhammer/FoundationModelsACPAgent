import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
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
    let context = try await AgentsToolTests.makeContext(label: "\(label)-\(name)")
    let built = try await SurfaceCatalog.makeRegistry(context: context)
    let selection = SurfaceCatalog.makeSearchSelection(profile: context.profile)
    let embedder = ProfileEmbedding(embedder: context.profile.embedding)
    let mounted = try built.registry.makeSessionTools(selection: selection, embedder: embedder)
    let runTools = AgentsComposition.makeRunTools(
      registry: built.registry, mcpServerNames: [], selection: selection, embedder: embedder,
      mounted: mounted)
    let definition = try SessionAgentToolsTests.definition(keys: keys)
    let resolved = try await ToolResolver(agent: definition.id, provenance: definition.provenance)
      .resolve(definition, catalog: runTools, agentsTool: nil)
    return ResolvedRun(
      nouns: try runCodeNouns(in: resolved.tools), diagnostics: resolved.diagnostics)
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

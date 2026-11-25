import ACPImport
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentKanban
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import FoundationModelsSkills
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `AgentComposition` (cli-plan.md §5.10): the model choice of the
/// executable selects the deterministic echo model in place of the live
/// loader, the composition says so, and two runs of one prompt through
/// it give byte-identical text.
@Suite(.closesHarnesses, .stubModel) struct AgentCompositionTests {
  // MARK: - Constants

  /// The prompt of the two runs. The echo model answers with the prompt
  /// it received, so the answer text carries it.
  private static let promptText = "echo this back"

  /// The path of the chunk gate that the gated stub choice carries.
  private static let chunkGatePath = "/tmp/chunk-gate"

  /// The path of the script that the scripted stub choice carries.
  private static let scriptPath = "/tmp/stub-script.json"

  /// The id of the skill that Multitool ships in its built-in skills
  /// folder.
  private static let builtinSkillID = "sessions"

  // MARK: - The model choice

  /// A stub model choice selects the stub model source. The suite trait
  /// `.stubModel` binds that choice.
  @Test func aStubChoiceSelectsTheStubModelSource() {
    #expect(AgentComposition.modelSource() == .stub)
  }

  /// The live model choice selects the live loader.
  @Test func theLiveChoiceSelectsTheLiveModelSource() {
    AgentComposition.$modelChoice.withValue(.live) {
      #expect(AgentComposition.modelSource() == .live)
    }
  }

  /// A stub choice with a gate gives the path of the gate to the
  /// composition.
  @Test func aStubChoiceGivesItsChunkGate() {
    let choice = AgentModelChoice.stub(chunkGate: Self.chunkGatePath, script: nil)
    AgentComposition.$modelChoice.withValue(choice) {
      #expect(AgentComposition.stubChunkGate() == Self.chunkGatePath)
    }
  }

  /// A stub choice with a script gives the path of the script to the
  /// composition.
  @Test func aStubChoiceGivesItsScript() {
    let choice = AgentModelChoice.stub(chunkGate: nil, script: Self.scriptPath)
    AgentComposition.$modelChoice.withValue(choice) {
      #expect(AgentComposition.stubScript() == Self.scriptPath)
    }
  }

  /// The live choice gives neither a gate nor a script, so the live path
  /// reads no stub file.
  @Test func theLiveChoiceGivesNoStubFile() {
    AgentComposition.$modelChoice.withValue(.live) {
      #expect(AgentComposition.stubChunkGate() == nil && AgentComposition.stubScript() == nil)
    }
  }

  /// The dotfolder name is the one the tier-3 fixture writes its user
  /// configuration under, and it is a valid name.
  @Test func theDotfolderNameIsValid() throws {
    let name = try DotfolderName(AgentComposition.dotfolderName)

    #expect(name.rawValue == "acp-agent")
  }

  /// The settings folders of the CLI are over the home of the CLI.
  @Test func theSettingsFoldersOfTheCLIAreOverTheHomeOfTheCLI() throws {
    let home = makeResolvedDirectory(label: "AgentCompositionTests-folders-home")
    let environment = [AgentComposition.homeVariable: home.path]

    let folders = try AgentComposition.settingsFolders(environment: environment)

    #expect(try folders.home == AgentComposition.home(environment: environment))
  }

  /// The settings folders of the CLI have the dotfolder name of the CLI.
  @Test func theSettingsFoldersOfTheCLIHaveTheDotfolderNameOfTheCLI() throws {
    let folders = try AgentComposition.settingsFolders(environment: [:])

    #expect(folders.name.rawValue == AgentComposition.dotfolderName)
  }

  // MARK: - The secret store

  /// The CLI gives the agent the login Keychain, under the service
  /// `acp-agent` (task ^y5zy1hz).
  @Test func theCompositionGivesTheLoginKeychainOfTheCLI() async throws {
    let configHome = makeResolvedDirectory(label: "AgentCompositionTests-secrets-config")
    let workspace = makeResolvedDirectory(label: "AgentCompositionTests-secrets-repo")
    let environment = try ComposedPromptFixture.makeStubEnvironment(configHome: configHome)

    let composed = try await AgentComposition.compose(
      workingDirectory: workspace, environment: environment,
      homeDirectory: makeResolvedDirectory(label: "AgentCompositionTests-home"))

    #expect(
      composed.agent.secretStore as? KeychainSecretStore
        == KeychainSecretStore(service: "acp-agent", synchronizable: false))
  }

  // MARK: - The built-in skills

  /// The skills stack of the CLI has the built-in skills of Multitool, thus
  /// a registry over it gives the `sessions` skill from the `defaults`
  /// layer.
  @Test func theSkillsStackOfTheCLIGivesTheBuiltinSkill() throws {
    let home = makeResolvedDirectory(label: "AgentCompositionTests-skills-home")
    let workspace = makeResolvedDirectory(label: "AgentCompositionTests-skills-repo")
    let loader = try AgentComposition.makeConfigurationLoader(
      workingDirectory: workspace, environment: [AgentComposition.homeVariable: home.path])

    let registry = SkillsRegistry(
      stack: loader.settingsFolders.stack(for: .skills, workingDirectory: workspace), mode: .open)

    #expect(registry.records().first { $0.id == Self.builtinSkillID }?.layer == .defaults)
  }

  // MARK: - The tool mode

  /// The CLI composes in the `open` tool mode (ACPA-19b): it runs outside
  /// the App Sandbox, so each session gets the shell, the stdio MCP servers
  /// and the code context.
  @Test func theCompositionOfTheCLIIsInTheOpenMode() async throws {
    let configHome = makeResolvedDirectory(label: "AgentCompositionTests-mode-config")
    let workspace = makeResolvedDirectory(label: "AgentCompositionTests-mode-repo")
    let environment = try ComposedPromptFixture.makeStubEnvironment(configHome: configHome)

    let composed = try await AgentComposition.compose(
      workingDirectory: workspace, environment: environment,
      homeDirectory: makeResolvedDirectory(label: "AgentCompositionTests-home"))

    #expect(composed.agent.toolMode == .open)
  }

  // MARK: - The kanban tool

  /// The composition of the CLI gives the `kanban` tool to each session:
  /// the session has the `kanban` endpoint.
  @Test func theCompositionOfTheCLIGivesTheKanbanToolToEachSession() async throws {
    let configHome = makeResolvedDirectory(label: "AgentCompositionTests-kanban-config")
    let workspace = makeResolvedDirectory(label: "AgentCompositionTests-kanban-repo")
    let environment = try ComposedPromptFixture.makeStubEnvironment(configHome: configHome)
    let composed = try await AgentComposition.compose(
      workingDirectory: workspace, environment: environment,
      homeDirectory: makeResolvedDirectory(label: "AgentCompositionTests-home"))
    let harness = await AgentClientHarness.makeRecording(agent: composed.agent)
    _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())

    let session = try await harness.connection.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))

    let endpoints = await composed.agent.sessions[session.sessionId]?.surface.graphQLEndpoints ?? []
    #expect(endpoints.map(\.name).contains(KanbanOperationTool.noun))
    await harness.close()
  }

  // MARK: - The stub composition

  /// With the stub selected the composition returns the echo model, and
  /// two runs of one prompt give byte-identical text that carries the
  /// prompt. No weights load and no network is touched, and the test waits
  /// on no clock.
  @Test
  func theStubCompositionEchoesByteIdenticalText() async throws {
    let configHome = makeResolvedDirectory(label: "AgentCompositionTests-config")
    let workspace = makeResolvedDirectory(label: "AgentCompositionTests-repo")
    let environment = try ComposedPromptFixture.makeStubEnvironment(configHome: configHome)

    let first = try await ComposedPromptFixture.answerText(
      environment: environment, workspace: workspace, prompt: Self.promptText)
    let second = try await ComposedPromptFixture.answerText(
      environment: environment, workspace: workspace, prompt: Self.promptText)

    #expect(!first.isEmpty)
    #expect(first.contains(Self.promptText))
    #expect(first == second)
  }

  // MARK: - The recorder of the composed router

  /// One prompt of the composed agent writes
  /// `<recording root>/<sessionId>/transcript.jsonl`, and the file holds
  /// the events of that prompt.
  ///
  /// The composition is the only shipped call site that builds the
  /// router, so it is the only place that can enable the recorder. With
  /// no recordings directory the router holds the no-op sink, every
  /// event goes nowhere, and `--resume` has nothing to read.
  ///
  /// The assertion reads the recorded file. It never reads the
  /// `index.md` of the session folder: Router writes that record on a
  /// path that never touches the recorder, so it stays correct while
  /// every event drops.
  @Test
  func theComposedPromptRecordsTheSessionTranscript() async throws {
    let configHome = makeResolvedDirectory(label: "AgentCompositionTests-record-config")
    let workspace = makeResolvedDirectory(label: "AgentCompositionTests-record-repo")
    let environment = try ComposedPromptFixture.makeStubEnvironment(configHome: configHome)

    let outcome = try await ComposedPromptFixture.run(
      environment: environment, workspace: workspace, prompt: Self.promptText)

    let root = try Self.recordingRoot(of: workspace)
    let file = RecordedTranscriptFile.fileURL(
      under: root, sessionId: outcome.sessionId.rawValue)
    #expect(
      FileManager.default.fileExists(atPath: file.path),
      "no transcript stands at \(file.path)")
    let lines = try RecordedTranscriptFile.lines(under: root, sessionId: outcome.sessionId)
    #expect(!lines.isEmpty)
    #expect(lines.contains { $0.kind == TranscriptEvent.Kind.session.rawValue })
  }

  /// The router the composition built records: a session of its resident
  /// profile writes a transcript under the root it was given.
  ///
  /// This case names the cause and not only the symptom. It goes around
  /// the agent's own session pipeline and drives the resolved profile
  /// itself, so a pass says the recorder of the composed router writes,
  /// and a failure says the router holds the no-op sink.
  @Test
  func theComposedRouterRecordsThroughItsResidentProfile() async throws {
    let configHome = makeResolvedDirectory(label: "AgentCompositionTests-router-config")
    let workspace = makeResolvedDirectory(label: "AgentCompositionTests-router-repo")
    let environment = try ComposedPromptFixture.makeStubEnvironment(configHome: configHome)
    let composed = try await AgentComposition.compose(
      workingDirectory: workspace, environment: environment,
      homeDirectory: makeResolvedDirectory(label: "AgentCompositionTests-home"))
    let root = try Self.recordingRoot(of: workspace)

    let session = composed.agent.residentProfile.standard.makeSession(
      workingDirectory: workspace, recordingRoot: root)
    _ = try await session.respond(to: Self.promptText)
    await session.close()

    let file = RecordedTranscriptFile.fileURL(
      under: root, sessionId: session.id.description)
    #expect(
      FileManager.default.fileExists(atPath: file.path),
      "the composed router recorded nothing at \(file.path)")
  }

  // MARK: - The import roots

  /// The home folder of the import root tests.
  private static let importHome = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

  /// With no `CLAUDE_CONFIG_DIR`, the CLI gives `~/.claude` and `~/.codex` of the real home
  /// folder as the import roots (D209).
  @Test func theImportRootsAreTheFoldersOfTheHome() {
    let roots = AgentComposition.importRoots(environment: [:], homeDirectory: Self.importHome)

    #expect(
      roots == [
        .claudeCode: Self.importHome.appendingPathComponent(".claude", isDirectory: true),
        .codex: Self.importHome.appendingPathComponent(".codex", isDirectory: true),
      ])
  }

  /// `CLAUDE_CONFIG_DIR` names the Claude Code import root.
  @Test func claudeConfigDirNamesTheClaudeCodeRoot() {
    let roots = AgentComposition.importRoots(
      environment: ["CLAUDE_CONFIG_DIR": "/elsewhere/claude"], homeDirectory: Self.importHome)

    #expect(roots[.claudeCode] == URL(fileURLWithPath: "/elsewhere/claude", isDirectory: true))
  }

  /// A `CLAUDE_CONFIG_DIR` that is not an absolute path gives a warning that names the variable.
  /// The root stays `~/.claude`.
  @Test func aRelativeClaudeConfigDirGivesAWarning() async throws {
    let (roots, records) = try await TelemetryCapture.run(forbidding: []) { context in
      let roots = AgentComposition.importRoots(
        environment: [AgentComposition.claudeConfigVariable: "relative/claude"],
        homeDirectory: Self.importHome)
      return (roots, context.logRecords)
    }

    let variable = Logger.MetadataValue.string(AgentComposition.claudeConfigVariable)
    #expect(
      records.contains {
        $0.level == .warning && $0.metadata[AgentComposition.variableMetadataKey] == variable
      })
    #expect(
      roots[.claudeCode] == Self.importHome.appendingPathComponent(".claude", isDirectory: true))
  }

  /// The recording root of `workspace` under the CLI's own dotfolder
  /// name, which is the default `project` location: `<cwd>/.<name>/transcripts/`.
  ///
  /// - Parameter workspace: The session working directory.
  /// - Returns: The recording root.
  private static func recordingRoot(of workspace: URL) throws -> URL {
    try projectRecordingRoot(
      of: workspace, dotfolderName: AgentComposition.dotfolderName)
  }
}

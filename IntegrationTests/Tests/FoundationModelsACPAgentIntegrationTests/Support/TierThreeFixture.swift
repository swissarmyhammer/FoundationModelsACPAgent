// `TierThreeFixture` — the shared setup of the tier-3 suites.
//
// `StdioContractTests` and `ClientServerTests` both spawn built binaries
// across a real process boundary, and inject the same shipped-profile user
// configuration. This one home keeps the names and the configuration in
// one place, so the two suites cannot drift apart.
//
// The suites carry no gate. This package is the gate: the root
// `swift test` never sees these targets, and
// `swift test --package-path IntegrationTests` runs them.

import Foundation
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras

/// The shared constants and fixtures of the tier-3 suites.
enum TierThreeFixture {
  /// The product name of the agent CLI executable the suites spawn.
  static let agentExecutableName = "acp-agent"

  /// The product name of the test-only stub agent executable: the command
  /// tree of ``agentExecutableName`` over the deterministic stub model.
  /// The shipped binary reads no environment variable to switch to a stub,
  /// so a suite that needs a model that is deterministic across a process
  /// boundary spawns this binary.
  static let stubAgentExecutableName = "acp-agent-stub"

  /// The subcommand that serves ACP over stdio (cli-plan.md §5.3). Bare
  /// `acp-agent` is `run`, which treats a piped stdin as a prompt, so
  /// every spawn of the wire names this one.
  static let acpSubcommand = "acp"

  /// The dotfolder name the agent CLI chose. The frontend chooses the
  /// name, and every path derives from it. The user
  /// configuration layer is `$XDG_CONFIG_HOME/<name>/config.yaml`.
  static let agentDotfolderName = "acp-agent"

  /// The environment variable that roots the user configuration layer.
  static let configHomeVariable = "XDG_CONFIG_HOME"

  /// The environment variable that roots the defaults layer of the agent
  /// configuration: `<NAME>_DEFAULTS_DIR` of `DotfolderStack`, with the
  /// dotfolder name in upper case. The agent gives no defaults folder of
  /// its own, so an empty value names no defaults layer.
  static let defaultsDirectoryVariable =
    agentDotfolderName.uppercased() + StubAgentDefaultsLayer.environmentKeySuffix

  /// The value of ``defaultsDirectoryVariable`` that names no defaults
  /// layer. A test that gives it reads the shipped configuration of a
  /// stock install, with no offline defaults layer.
  static let noDefaultsLayerValue = ""

  /// The `config.yaml` of the offline defaults layer: an empty skills
  /// marketplace list.
  ///
  /// The shipped list names the `swissarmyhammer/skills` repository on
  /// GitHub, and a session start fetches each marketplace. The suites of
  /// this package must be offline and repeatable, thus each child reads
  /// this layer (see ``makeOfflineDefaultsEnvironment()``). The defaults
  /// layer is the lowest layer, so the user layer or the project layer of
  /// a test still sets each other value. `SkillsMarketplaceNetworkTests`
  /// proves the shipped list on purpose.
  static let offlineDefaultsYAML = "tools:\n  skills:\n    marketplaces: []\n"

  /// Writes the offline defaults layer into a fresh folder, and returns
  /// the pair that names that folder as the defaults layer of the agent.
  ///
  /// `PipedChildProcess` gives the pair to each child it spawns, and
  /// `StdioContractTests` sets it on this process for its `AgentProcess`.
  ///
  /// - Returns: ``defaultsDirectoryVariable`` and the folder of the layer.
  /// - Throws: The directory-creation or write error.
  static func makeOfflineDefaultsEnvironment() throws -> [String: String] {
    let root = makeResolvedDirectory(label: "OfflineDefaultsLayer")
    try ConfigFileFixture.write(offlineDefaultsYAML, in: root)
    return [defaultsDirectoryVariable: root.path]
  }

  /// The environment variable that gates the stub model: the path of a
  /// named pipe that the stub reads one byte from before each chunk of
  /// the echoed prompt. It is what holds a prompt open until a signal
  /// landed inside it (cli-plan.md §5.9), with no clock. The variable
  /// carries a path into a stub binary that always runs; it does not
  /// choose the model.
  static let stubChunkGateVariable = "ACP_AGENT_STUB_CHUNK_GATE"

  /// The environment variable with the path of the JSON script file of the
  /// stub model (`ScriptedStubScript`). Like the gate, it carries a path
  /// into a stub binary that always runs.
  static let stubScriptVariable = "ACP_AGENT_STUB_SCRIPT"

  /// Writes `text` as the script file of a stub run, in a fresh directory.
  ///
  /// - Parameters:
  ///   - text: The JSON text of the script (`ScriptedStubScript`).
  ///   - label: The directory label, so a leftover directory says where it
  ///     came from.
  /// - Returns: The file. Its path is the value of ``stubScriptVariable``.
  /// - Throws: The write error.
  static func writeStubScript(_ text: String, label: String) throws -> URL {
    let file = makeResolvedDirectory(label: "\(label)-script").appendingPathComponent("script.json")
    try text.write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  /// The environment of a stub run over a script file: the offline defaults
  /// layer, and the pair that names `file` as the script of the stub model.
  ///
  /// - Parameter file: The script file (``writeStubScript(_:label:)``).
  /// - Returns: The environment pairs to give a spawned run.
  /// - Throws: The directory-creation or write error.
  static func stubScriptEnvironment(file: URL) throws -> [String: String] {
    try makeOfflineDefaultsEnvironment()
      .merging([stubScriptVariable: file.path]) { _, script in script }
  }

  /// The path of a gate file that never exists, so a script step that waits for it holds until
  /// the limit of the child ends the run.
  ///
  /// - Parameter label: The directory label of the gate.
  /// - Returns: The path of the gate file.
  static func neverOpenedGateFile(label: String) -> URL {
    makeResolvedDirectory(label: "\(label)-gate").appendingPathComponent("never")
  }

  /// Makes the named pipe of a chunk gate in a fresh directory, and the
  /// environment pair that names it to the stub binary. The run
  /// (``SignalledExecutableRun``) holds the write end, so a prompt stays
  /// open until this process read what a live run carries, or sent its
  /// signal.
  ///
  /// - Parameter label: The directory label, so a leftover directory says
  ///   where it came from.
  /// - Returns: The pipe, and the pairs to give a spawned run.
  /// - Throws: The `mkfifo` error.
  static func gatedStubModel(label: String) throws -> (gate: URL, environment: [String: String]) {
    let gate = makeResolvedDirectory(label: "\(label)-gate").appendingPathComponent("chunks")
    try StubChunkGateWriter.makePipe(at: gate)
    return (gate, [stubChunkGateVariable: gate.path])
  }

  /// Runs the built `acp-agent-stub` over the gated stub model, in fresh
  /// directories, and sends `signalCount` interrupts once its first answer
  /// bytes arrive. The gate holds the prompt after its first chunk, so each
  /// signal lands inside the prompt.
  ///
  /// - Parameters:
  ///   - arguments: The command-line arguments for the agent.
  ///   - label: The directory label, so a leftover directory says where it
  ///     came from.
  ///   - signalCount: How many `SIGINT`s to send. Zero runs the prompt to
  ///     its end.
  ///   - atFirstOutput: What to do once the child has written its first
  ///     stdout byte, with the child's process identifier.
  /// - Returns: The finished run.
  /// - Throws: The wait, locator or spawn error, or what `atFirstOutput` throws.
  static func runGatedStubAgent(
    arguments: [String],
    label: String,
    signalCount: Int,
    atFirstOutput: @Sendable (pid_t) async throws -> Void = { _ in }
  ) async throws -> SignalledExecutableRun {
    let gated = try gatedStubModel(label: label)
    return try await SignalledExecutableRun.run(
      executableNamed: stubAgentExecutableName,
      arguments: arguments,
      workspace: makeResolvedDirectory(label: "\(label)-repo"),
      configHome: makeResolvedDirectory(label: "\(label)-config"),
      environment: gated.environment,
      atFirstOutput: atFirstOutput,
      signalCount: signalCount,
      chunkGate: gated.gate)
  }

  /// The user-layer `config.yaml` the spawned agent resolves its
  /// profile from: the shipped profile, slot for slot.
  ///
  /// The tests drive the models the agent ships, so a pass says the
  /// shipped agent works, and a change of a default reaches the tests
  /// with no edit here.
  static var userConfigYAML: String {
    """
    profile:
      standard: ["\(shippedModel(ProfileConfiguration.defaultStandard))"]
      flash: ["\(shippedModel(ProfileConfiguration.defaultFlash))"]
      embedding: ["\(shippedModel(ProfileConfiguration.defaultEmbedding))"]
    """
  }

  /// The first model of one shipped slot.
  ///
  /// - Parameter slot: The shipped default of the slot.
  /// - Returns: The model reference.
  private static func shippedModel(_ slot: [ModelRef]) -> String {
    guard let first = slot.first?.stringValue else {
      preconditionFailure("a shipped profile slot names no model")
    }
    return first
  }

  /// Writes the user-layer `config.yaml` under `configHome`, at
  /// `<configHome>/<dotfolder name>/config.yaml`.
  ///
  /// - Parameters:
  ///   - configHome: The injected `XDG_CONFIG_HOME` root.
  ///   - yaml: The configuration to write; the shipped-profile default
  ///     resolves a real profile.
  /// - Throws: The directory-creation or write error.
  static func writeUserConfig(under configHome: URL, yaml: String = userConfigYAML) throws {
    try ConfigFileFixture.write(
      yaml, in: configHome.appendingPathComponent(agentDotfolderName, isDirectory: true))
  }
}

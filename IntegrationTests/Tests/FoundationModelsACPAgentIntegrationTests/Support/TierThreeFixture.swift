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
    /// a test still sets each other value. `SkillsMarketplaceProcessTests`
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

    /// The environment variable that selects the deterministic stub
    /// model, and the value that selects it. `AgentComposition` in the
    /// root package declares both; this package cannot import an
    /// executable module, so the two names stand here as well.
    static let stubModelVariable = "ACP_AGENT_STUB_MODEL"

    /// The value of ``stubModelVariable`` that selects the stub model.
    static let stubModelEnabledValue = "1"

    /// The environment variable that gates the stub model: the path of a
    /// named pipe that the stub reads one byte from before each chunk of
    /// the echoed prompt. It is what holds a prompt open until a signal
    /// landed inside it (cli-plan.md §5.9), with no clock.
    static let stubChunkGateVariable = "ACP_AGENT_STUB_CHUNK_GATE"

    /// The environment pairs that select the deterministic stub model.
    ///
    /// A spawned binary passes them on to every binary it spawns, so one
    /// pair reaches an agent standing two process boundaries away.
    static let stubModelEnvironment = [stubModelVariable: stubModelEnabledValue]

    /// Makes the named pipe of a chunk gate in a fresh directory, and the
    /// environment pairs that select the stub model and gate it. The run
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
        return (gate, stubModelEnvironment.merging([stubChunkGateVariable: gate.path]) { _, gated in gated })
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

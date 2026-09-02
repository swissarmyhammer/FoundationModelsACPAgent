// `TierThreeFixture` — the shared setup of the gated tier-3 suites.
//
// `StdioContractTests` and `ClientServerTests` both spawn built binaries
// across a real process boundary, gate on the same environment variable,
// and inject the same small-model user configuration. This one home keeps
// the gate, the names, and the configuration in one place, so the two
// suites cannot drift apart.

import Foundation

@testable import FoundationModelsACPAgent

/// The shared constants and fixtures of the gated tier-3 suites.
enum TierThreeFixture {
    /// The environment variable that opens the tier-3 gate.
    static let gateVariable = "ACP_TIER3"

    /// The value of ``gateVariable`` that opens the gate.
    static let gateOpenValue = "1"

    /// Whether the tier-3 gate is open in this process.
    static var isGateOpen: Bool {
        ProcessInfo.processInfo.environment[gateVariable] == gateOpenValue
    }

    /// The product name of the agent example executable the suites spawn.
    static let agentExecutableName = "acp-agent"

    /// The dotfolder name the agent example chose (plan.md §20.2). The
    /// user configuration layer is `$XDG_CONFIG_HOME/<name>/config.yaml`.
    static let agentDotfolderName = "acp-agent"

    /// The environment variable that roots the user configuration layer.
    static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The user-layer `config.yaml` the spawned agent resolves its
    /// profile from: the small real `mlx-community` models the family's
    /// own gated suites load (Router's examples and Multitool's gated
    /// fixture), so the first run downloads little.
    static let userConfigYAML = """
        profile:
          standard: ["mlx-community/SmolLM-135M-Instruct-4bit"]
          flash: ["mlx-community/SmolLM-135M-Instruct-4bit"]
          embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"]
        """

    /// Writes the user-layer `config.yaml` under `configHome`, at
    /// `<configHome>/<dotfolder name>/config.yaml`.
    ///
    /// - Parameters:
    ///   - configHome: The injected `XDG_CONFIG_HOME` root.
    ///   - yaml: The configuration to write; the small-model default
    ///     resolves a real profile.
    /// - Throws: The directory-creation or write error.
    static func writeUserConfig(under configHome: URL, yaml: String = userConfigYAML) throws {
        let dotfolder = configHome.appendingPathComponent(agentDotfolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dotfolder, withIntermediateDirectories: true)
        try yaml.write(
            to: dotfolder.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
    }
}

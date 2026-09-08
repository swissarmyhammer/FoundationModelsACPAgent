// `TierThreeFixture` — the shared setup of the tier-3 suites.
//
// `StdioContractTests` and `ClientServerTests` both spawn built binaries
// across a real process boundary, and inject the same small-model user
// configuration. This one home keeps the names and the configuration in
// one place, so the two suites cannot drift apart.
//
// The suites carry no gate. This package is the gate: the root
// `swift test` never sees these targets, and
// `swift test --package-path IntegrationTests` runs them.

import Foundation
import FoundationModelsACPAgentTestSupport

/// The shared constants and fixtures of the tier-3 suites.
enum TierThreeFixture {
    /// The product name of the agent CLI executable the suites spawn.
    static let agentExecutableName = "acp-agent"

    /// The subcommand that serves ACP over stdio (cli-plan.md §5.3). Bare
    /// `acp-agent` is `run`, which treats a piped stdin as a prompt, so
    /// every spawn of the wire names this one.
    static let acpSubcommand = "acp"

    /// The dotfolder name the agent CLI chose (plan.md §20.2). The user
    /// configuration layer is `$XDG_CONFIG_HOME/<name>/config.yaml`.
    static let agentDotfolderName = "acp-agent"

    /// The environment variable that roots the user configuration layer.
    static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The environment variable that selects the deterministic stub
    /// model, and the value that selects it. `AgentComposition` in the
    /// root package declares both; this package cannot import an
    /// executable module, so the two names stand here as well.
    static let stubModelVariable = "ACP_AGENT_STUB_MODEL"

    /// The value of ``stubModelVariable`` that selects the stub model.
    static let stubModelEnabledValue = "1"

    /// The environment variable that paces the stub model: the pause, in
    /// milliseconds, between two chunks of the echoed prompt. It is what
    /// holds a turn open long enough for a signal to land inside it
    /// (cli-plan.md §5.9).
    static let stubChunkDelayVariable = "ACP_AGENT_STUB_CHUNK_DELAY_MS"

    /// The environment pairs that select the deterministic stub model.
    ///
    /// A spawned binary passes them on to every binary it spawns, so one
    /// pair reaches an agent standing two process boundaries away.
    static let stubModelEnvironment = [stubModelVariable: stubModelEnabledValue]

    /// The environment pairs that select the stub model and pace it, so a
    /// turn stays open long enough for this process to read what a live run
    /// carries.
    ///
    /// - Parameter chunkDelayMilliseconds: The pause between two chunks of
    ///   the echoed prompt.
    /// - Returns: The pairs to give a spawned run.
    static func pacedStubModelEnvironment(chunkDelayMilliseconds: Int) -> [String: String] {
        stubModelEnvironment.merging(
            [stubChunkDelayVariable: String(chunkDelayMilliseconds)]
        ) { _, paced in paced }
    }

    /// The user-layer `config.yaml` the spawned agent resolves its
    /// profile from: the small real `mlx-community` models the family's
    /// own integration suites load (Router's examples and Multitool's
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
        try ConfigFileFixture.write(
            yaml, in: configHome.appendingPathComponent(agentDotfolderName, isDirectory: true))
    }
}

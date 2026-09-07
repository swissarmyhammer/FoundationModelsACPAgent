import Foundation
import FoundationModelsACPAgentTestSupport

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// A throwaway two-layer tree for the `config` subcommands (cli-plan.md
/// §5.11): a workspace, and a config home injected as `XDG_CONFIG_HOME`,
/// so no test touches the real home directory. The dotfolder name is the
/// one the CLI composes with, because the subcommands take no name.
struct ConfigCommandFixture {
    /// The environment variable that roots the user configuration layer.
    static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The working directory; the project layer roots under it.
    let workspace: URL

    /// The injected `XDG_CONFIG_HOME` root; the user layer roots under it.
    let configHome: URL

    /// Makes the two directories under `/private/tmp`.
    ///
    /// - Parameter label: The prefix that names the calling suite.
    init(label: String) {
        workspace = makeResolvedDirectory(label: "\(label)-repo")
        configHome = makeResolvedDirectory(label: "\(label)-config")
    }

    /// The environment the subcommands read: the config home, and nothing
    /// else.
    var environment: [String: String] {
        [Self.configHomeVariable: configHome.path]
    }

    /// The environment a composing subcommand reads: ``environment``, and
    /// the switch that selects the stub model (cli-plan.md §9), so no
    /// weights load and no network is touched.
    var stubEnvironment: [String: String] {
        var stub = environment
        stub[AgentComposition.stubModelVariable] = AgentComposition.stubModelEnabledValue
        return stub
    }

    /// The user layer root, `<configHome>/<name>/`.
    var userDirectory: URL {
        configHome.appendingPathComponent(AgentComposition.dotfolderName, isDirectory: true)
    }

    /// The project layer root, `<workspace>/.<name>/`.
    var projectDirectory: URL {
        workspace.appendingPathComponent(".\(AgentComposition.dotfolderName)", isDirectory: true)
    }

    /// The `config.yaml` path inside one layer root.
    ///
    /// The `config` subcommands and the `/config export` slash command
    /// all write that one file name, so one helper names it for every
    /// suite that reads what they wrote.
    ///
    /// - Parameter directory: The layer root.
    /// - Returns: The file URL.
    static func configURL(in directory: URL) -> URL {
        directory.appendingPathComponent(ConfigurationLoader.configFileName)
    }

    /// The UTF-8 text of the file at `url`.
    ///
    /// - Parameter url: The file to read.
    /// - Returns: The content as text.
    /// - Throws: The read error, which a missing file also gives.
    static func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes `yaml` as the project layer's `config.yaml`.
    ///
    /// - Parameter yaml: The file content.
    /// - Throws: The directory-creation or write error.
    func writeProjectConfig(_ yaml: String) throws {
        try ConfigFileFixture.write(yaml, in: projectDirectory)
    }

    /// Writes `yaml` as the user layer's `config.yaml`.
    ///
    /// - Parameter yaml: The file content.
    /// - Throws: The directory-creation or write error.
    func writeUserConfig(_ yaml: String) throws {
        try ConfigFileFixture.write(yaml, in: userDirectory)
    }

    /// Writes a project `config.yaml` that sets `compaction.trigger`.
    ///
    /// The key is inert: it changes no model and no tool, so a resolved
    /// value names exactly one project layer and nothing else. A test
    /// that must say WHICH stack a load read writes this key.
    ///
    /// - Parameter trigger: The value to write.
    /// - Throws: The directory-creation or write error.
    func writeProjectCompactionTrigger(_ trigger: Double) throws {
        try writeProjectConfig("compaction:\n  trigger: \(trigger)\n")
    }
}

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

    /// The user layer root, `<configHome>/<name>/`.
    var userDirectory: URL {
        configHome.appendingPathComponent(AgentComposition.dotfolderName, isDirectory: true)
    }

    /// The project layer root, `<workspace>/.<name>/`.
    var projectDirectory: URL {
        workspace.appendingPathComponent(".\(AgentComposition.dotfolderName)", isDirectory: true)
    }

    /// Writes `yaml` as the project layer's `config.yaml`.
    ///
    /// - Parameter yaml: The file content.
    /// - Throws: The directory-creation or write error.
    func writeProjectConfig(_ yaml: String) throws {
        try Self.writeConfig(yaml, in: projectDirectory)
    }

    /// Writes `yaml` as the user layer's `config.yaml`.
    ///
    /// - Parameter yaml: The file content.
    /// - Throws: The directory-creation or write error.
    func writeUserConfig(_ yaml: String) throws {
        try Self.writeConfig(yaml, in: userDirectory)
    }

    /// Writes `yaml` as `config.yaml` inside `directory`, creating it.
    private static func writeConfig(_ yaml: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try yaml.write(
            to: directory.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
    }
}

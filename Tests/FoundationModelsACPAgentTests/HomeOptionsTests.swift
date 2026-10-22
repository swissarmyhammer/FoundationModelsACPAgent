import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The home of the CLI (task ^98a44n7): `--home <dir>` and `ACP_AGENT_HOME`
/// resolve through the one function `AgentComposition.home(environment:)`
/// to the custom home `<dir>/synced` and `<dir>/local`. With neither, the
/// home is the XDG home of today.
@Suite struct HomeOptionsTests {
    // MARK: - Constants

    /// The prompt of a parsed `run`.
    private static let promptText = "hello"

    /// A relative home folder, which resolves against the process working
    /// directory.
    private static let relativeHome = "relative-home"

    /// An XDG environment of a test, so the XDG home reads no real folder.
    private static let xdgEnvironment = [
        "XDG_CONFIG_HOME": "/tmp/home-options-config",
        "XDG_DATA_HOME": "/tmp/home-options-data",
    ]

    // MARK: - The variable

    /// `ACP_AGENT_HOME=<dir>` gives the custom home over `<dir>/synced` and
    /// `<dir>/local`.
    @Test func theVariableGivesACustomHomeInTheFolder() throws {
        let folder = makeResolvedDirectory(label: "HomeOptions-variable")

        let home = try AgentComposition.home(
            environment: [AgentComposition.homeVariable: folder.path])

        #expect(home == Self.customHome(in: folder))
    }

    /// A relative `ACP_AGENT_HOME` resolves against the process working
    /// directory.
    @Test func aRelativeVariableResolvesAgainstTheProcessWorkingDirectory() throws {
        let folder = AgentComposition.processWorkingDirectory
            .appendingPathComponent(Self.relativeHome, isDirectory: true)

        let home = try AgentComposition.home(
            environment: [AgentComposition.homeVariable: Self.relativeHome])

        #expect(home.synced.standardizedFileURL == Self.customHome(in: folder).synced.standardizedFileURL)
        #expect(home.local.standardizedFileURL == Self.customHome(in: folder).local.standardizedFileURL)
    }

    /// With no variable, and with an empty one, the home is the XDG home of
    /// the dotfolder name: the folders of today.
    @Test func noVariableGivesTheXDGHome() throws {
        let xdg = AgentHome.xdg(
            name: try DotfolderName(AgentComposition.dotfolderName), environment: Self.xdgEnvironment)
        var empty = Self.xdgEnvironment
        empty[AgentComposition.homeVariable] = ""

        #expect(try AgentComposition.home(environment: Self.xdgEnvironment) == xdg)
        #expect(try AgentComposition.home(environment: empty) == xdg)
    }

    // MARK: - The option

    /// `--home <dir>` gives the same home as `ACP_AGENT_HOME=<dir>`, and wins
    /// over the variable.
    @Test func theOptionResolvesAsTheVariable() throws {
        let folder = makeResolvedDirectory(label: "HomeOptions-option")
        let other = makeResolvedDirectory(label: "HomeOptions-other")
        let options = try HomeOptions.parse(["--home", folder.path])
        let base = Self.xdgEnvironment.merging([AgentComposition.homeVariable: other.path]) { _, new in new }

        let fromOption = try AgentComposition.home(environment: options.environment(over: base))
        let fromVariable = try AgentComposition.home(
            environment: [AgentComposition.homeVariable: folder.path])

        #expect(fromOption == fromVariable)
    }

    /// With no `--home`, the environment is the base environment.
    @Test func noOptionKeepsTheBaseEnvironment() throws {
        let options = try HomeOptions.parse([])

        #expect(options.environment(over: Self.xdgEnvironment) == Self.xdgEnvironment)
    }

    /// `run --home <dir>` parses onto the home options of `run`.
    @Test func runTakesTheOption() throws {
        let folder = makeResolvedDirectory(label: "HomeOptions-run")
        let run = try #require(
            try AcpAgentCommand.parseAsRoot(["run", "--home", folder.path, Self.promptText])
                as? AcpAgentCommand.Run)

        #expect(run.homeOptions.home == folder.path)
    }

    // MARK: - Helpers

    /// The custom home that the CLI makes in one folder: its synced and its
    /// local folder.
    ///
    /// - Parameter folder: The folder of the home.
    /// - Returns: The home.
    private static func customHome(in folder: URL) -> AgentHome {
        .custom(
            synced: folder.appendingPathComponent(AgentComposition.syncedFolderName, isDirectory: true),
            local: folder.appendingPathComponent(AgentComposition.localFolderName, isDirectory: true))
    }
}

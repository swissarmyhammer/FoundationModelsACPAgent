import ArgumentParser
import Foundation

/// The `--home` option of each subcommand that builds a stack or composes
/// the agent (task ^98a44n7): the folder of the home of the CLI. One
/// declaration, so the subcommands read the option, its help text and its
/// default alike.
///
/// The option does not resolve a home on its own. It sets
/// ``AgentComposition/homeVariable`` in the environment of the subcommand
/// (``environment(over:)``), so `--home` and `ACP_AGENT_HOME` resolve the
/// one way, through ``AgentComposition/home(environment:)``.
struct HomeOptions: ParsableArguments {
    /// The `--home` value, or `nil` for the home that `ACP_AGENT_HOME` names,
    /// or the XDG home.
    @Option(
        name: .customLong("home"),
        help:
            "The folder of the home: its synced and local folders. It wins over ACP_AGENT_HOME. Default: ACP_AGENT_HOME, or the XDG folders."
    )
    var home: String?

    /// The environment of the subcommand: `base` with
    /// ``AgentComposition/homeVariable`` set to `--home` when the option is
    /// given.
    ///
    /// - Parameter base: The environment of the process.
    /// - Returns: `base`, or `base` with the home variable of `--home`.
    func environment(over base: [String: String]) -> [String: String] {
        guard let home else {
            return base
        }
        var environment = base
        environment[AgentComposition.homeVariable] = home
        return environment
    }
}

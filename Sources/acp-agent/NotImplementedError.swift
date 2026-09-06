import ArgumentParser

/// The failure every stub subcommand throws until its own card fills the
/// body (cli-plan.md §10): the process exits 1, with this text on stderr.
struct NotImplementedError: Error, CustomStringConvertible {
    /// The command name, as its `CommandConfiguration` states it.
    let commandName: String

    /// Names the stub by its command type.
    ///
    /// - Parameter command: The subcommand type whose body is the stub.
    init(command: any ParsableCommand.Type) {
        commandName = command.configuration.commandName ?? String(describing: command)
    }

    var description: String {
        "acp-agent \(commandName) is not implemented yet"
    }
}

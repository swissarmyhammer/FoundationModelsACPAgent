import ArgumentParser

extension AcpAgentCommand {
    /// `acp-agent config`: nothing is on disk after an install, so the
    /// configuration is invisible, and these subcommands make it visible
    /// (cli-plan.md §5.11). Each body is a stub until its card lands: it
    /// exits 1.
    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "Show, write, locate or edit the configuration.",
            subcommands: [Show.self, Init.self, Path.self, Edit.self])

        /// `config show`: print the merged configuration, and where each
        /// value came from.
        struct Show: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "show",
                abstract: "Print the merged configuration, and where each value came from.")

            mutating func run() throws {
                throw NotImplementedError(command: Self.self)
            }
        }

        /// `config init`: write a `config.yaml` with every key at its
        /// default.
        struct Init: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "init",
                abstract: "Write a config.yaml with every key at its default.")

            mutating func run() throws {
                throw NotImplementedError(command: Self.self)
            }
        }

        /// `config path`: print each layer path, and say which ones exist.
        struct Path: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "path",
                abstract: "Print each layer path, and say which ones exist.")

            mutating func run() throws {
                throw NotImplementedError(command: Self.self)
            }
        }

        /// `config edit`: open the nearest `config.yaml` in `$EDITOR`.
        struct Edit: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "edit",
                abstract: "Open the nearest config.yaml in $EDITOR.")

            mutating func run() throws {
                throw NotImplementedError(command: Self.self)
            }
        }
    }
}

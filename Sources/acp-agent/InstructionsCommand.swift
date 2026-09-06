import ArgumentParser

extension AcpAgentCommand {
    /// `acp-agent instructions`: the compiled-in instructions floor, and
    /// its wholesale replacement in a layer (plan.md §3.1, cli-plan.md
    /// §5.3). The body is a stub until its card lands: it exits 1.
    struct Instructions: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "instructions",
            abstract: "Work with the instructions text.",
            subcommands: [Eject.self])

        /// `instructions eject`: write `Instructions.md` into a layer.
        struct Eject: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "eject",
                abstract: "Write Instructions.md into a layer.")

            mutating func run() throws {
                throw NotImplementedError(command: Self.self)
            }
        }
    }
}

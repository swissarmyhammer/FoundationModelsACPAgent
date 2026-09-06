import ArgumentParser

extension AcpAgentCommand {
    /// `acp-agent doctor`: check that this configuration will actually
    /// work (cli-plan.md §5.12). The body is a stub until its card lands:
    /// it exits 1.
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "doctor",
            abstract: "Check that this configuration will actually work.")

        mutating func run() throws {
            throw NotImplementedError(command: Self.self)
        }
    }
}

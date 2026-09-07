import ArgumentParser
import Foundation
import Testing

@testable import acp_agent

/// The prompt-source table (cli-plan.md §5.5): where one `run` turn
/// takes its prompt from.
///
/// One test stands for each row of the table:
///
/// | Condition | Result |
/// |---|---|
/// | A prompt argument | Use it. |
/// | No prompt, and stdin is a pipe or a file | Read the prompt from stdin. |
/// | No prompt, and stdin is a terminal | Print the usage to stderr. Exit 2. |
/// | The prompt is `-` | Read the prompt from stdin, a terminal included. |
///
/// A `Pipe` carries stdin for the rows that read it, so no test needs a
/// terminal and no test reads the real stdin of the test process.
struct PromptSourceTests {
    // MARK: - Constants

    /// The prompt written on the command line.
    private static let argumentPrompt = "write a haiku"

    /// The prompt piped into stdin. It differs from
    /// ``argumentPrompt`` so an assertion says WHICH source was read.
    ///
    /// The trailing newline is the one `echo` adds, so the piped text is
    /// what `echo "..." | acp-agent` really sends.
    private static let pipedPrompt = "write a limerick\n"

    // MARK: - Fixtures

    /// A read handle carrying `text`, with the write end already closed
    /// so a read to the end returns.
    ///
    /// - Parameter text: The bytes stdin carries.
    /// - Returns: The read end of the pipe.
    /// - Throws: The write or the close error.
    private static func standardInput(carrying text: String) throws -> FileHandle {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        return pipe.fileHandleForReading
    }

    /// A source over a piped stdin carrying ``pipedPrompt``.
    ///
    /// - Parameters:
    ///   - argument: The prompt argument, or `nil` for none.
    ///   - isTerminal: What the source is told about stdin.
    /// - Returns: The source.
    /// - Throws: The pipe error.
    private static func source(
        argument: String?, standardInputIsTerminal isTerminal: Bool
    ) throws -> PromptSource {
        PromptSource(
            argument: argument,
            standardInput: try standardInput(carrying: pipedPrompt),
            standardInputIsTerminal: isTerminal)
    }

    // MARK: - Row 1: a prompt argument

    /// A prompt argument is the prompt, and stdin is left alone. The
    /// piped text differs from the argument, so an argument that lost to
    /// stdin would fail here.
    @Test func aPromptArgumentIsThePrompt() throws {
        let source = try Self.source(
            argument: Self.argumentPrompt, standardInputIsTerminal: false)

        #expect(try source.text() == Self.argumentPrompt)
    }

    // MARK: - Row 2: no prompt, and stdin is a pipe or a file

    /// With no prompt argument and a piped stdin, the prompt is the
    /// bytes of stdin. This is `echo "hello" | acp-agent`.
    @Test func aPipedStandardInputIsThePromptWhenNoArgumentIsGiven() throws {
        let source = try Self.source(argument: nil, standardInputIsTerminal: false)

        #expect(try source.text() == Self.pipedPrompt)
    }

    // MARK: - Row 3: no prompt, and stdin is a terminal

    /// With no prompt argument and a terminal stdin, the run is a usage
    /// error. `ValidationError` is what ArgumentParser prints as the
    /// usage on stderr, and it exits 2.
    @Test func aTerminalStandardInputWithNoArgumentIsAUsageError() throws {
        let source = try Self.source(argument: nil, standardInputIsTerminal: true)

        #expect(throws: ValidationError.self) {
            _ = try source.text()
        }
    }

    // MARK: - Row 4: the prompt is `-`

    /// The prompt `-` reads stdin, a terminal included. The source is
    /// told stdin is a terminal, and it reads stdin all the same.
    @Test func theDashArgumentReadsStandardInputEvenOnATerminal() throws {
        let source = try Self.source(
            argument: PromptSource.standardInputArgument, standardInputIsTerminal: true)

        #expect(try source.text() == Self.pipedPrompt)
    }

    // MARK: - The wiring

    /// The `run` subcommand takes its prompt through the table: the
    /// parsed argument is the source's argument, so no second rule
    /// stands beside the four rows.
    @Test func theRunSubcommandTakesItsPromptThroughTheTable() throws {
        let command = try #require(
            try AcpAgentCommand.parseAsRoot(["run", Self.argumentPrompt])
                as? AcpAgentCommand.Run)

        #expect(command.promptSource.argument == Self.argumentPrompt)
    }
}

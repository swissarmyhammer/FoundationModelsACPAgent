import ArgumentParser
import Darwin
import Foundation

/// Where one `run` turn takes its prompt from (cli-plan.md §5.5).
///
/// | Condition | Result |
/// |---|---|
/// | A prompt argument | Use it. |
/// | No prompt, and stdin is a pipe or a file | Read the prompt from stdin. |
/// | No prompt, and stdin is a terminal | Print the usage to stderr. Exit 2. |
/// | The prompt is `-` | Read the prompt from stdin, a terminal included. |
///
/// This gives `echo "hello" | acp-agent`, which is what a person
/// expects.
///
/// The table belongs to `run` alone. In `acp` mode stdin is the wire,
/// and that mode never looks at stdin for a prompt.
struct PromptSource {
    /// The prompt argument that names stdin, a terminal included.
    static let standardInputArgument = "-"

    /// What the terminal row says. A `ValidationError` carries it,
    /// because ArgumentParser prints such an error as the usage on
    /// stderr and exits 2 — which is the row.
    static let terminalMessage =
        "a prompt is necessary: give it as the argument, pipe it into stdin, or write `-` to read a terminal."

    /// The prompt argument, or `nil` when the command line carried none.
    let argument: String?

    /// The handle the prompt is read from when the table selects stdin.
    let standardInput: FileHandle

    /// Whether ``standardInput`` is a terminal. A pipe and a file are
    /// both not a terminal, and the table treats them alike.
    let standardInputIsTerminal: Bool

    /// The prompt text of the turn, by the table above.
    ///
    /// The bytes of stdin are the prompt as they arrive, with no trim.
    /// The table says read the prompt from stdin, and the newline a
    /// shell's `echo` adds changes no turn.
    ///
    /// - Returns: The prompt text.
    /// - Throws: `ValidationError` for the terminal row, and the read
    ///   error of stdin for the rows that read it.
    func text() throws -> String {
        guard let argument else {
            guard !standardInputIsTerminal else {
                throw ValidationError(Self.terminalMessage)
            }
            return try readStandardInput()
        }
        guard argument != Self.standardInputArgument else {
            return try readStandardInput()
        }
        return argument
    }

    /// Reads ``standardInput`` to the end.
    ///
    /// - Returns: The bytes read, as UTF-8 text.
    /// - Throws: The read error.
    private func readStandardInput() throws -> String {
        guard let data = try standardInput.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension PromptSource {
    /// Creates a source over the process's own stdin.
    ///
    /// The memberwise form takes a handle and a flag, so a test drives
    /// the stdin rows with a `Pipe` and needs no terminal.
    ///
    /// - Parameter argument: The prompt argument the parse gave, or
    ///   `nil` when the command line carried none.
    init(argument: String?) {
        self.init(
            argument: argument,
            standardInput: .standardInput,
            standardInputIsTerminal: isatty(STDIN_FILENO) == 1)
    }
}

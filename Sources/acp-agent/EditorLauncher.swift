import Foundation

/// The refusal that no editor is named (cli-plan.md §5.11).
///
/// `config edit` has nothing to open the file with, so it stops before it
/// touches a file. The message names the variable, so the recourse is in
/// the refusal itself, the way ``LayerFileExistsError`` names `--force`.
struct EditorNotNamedError: Error, CustomStringConvertible {
    /// The environment variable that carries no editor command.
    let variable: String

    var description: String {
        "\(variable) is not set; set it to the command that opens your editor"
    }
}

/// The refusal that the editor ended with a failure status.
///
/// The editor is the person's own program, so this command reports what
/// that program said and adds nothing to it.
struct EditorFailedError: Error, CustomStringConvertible {
    /// The editor command, as the person spelled it.
    let command: String

    /// The status the editor ended with.
    let status: Int32

    var description: String {
        "the editor \"\(command)\" exited with status \(status)"
    }
}

/// Opens one file in the editor `$EDITOR` names (cli-plan.md §5.11).
///
/// **The editor command is an argument, never a process global.** It
/// comes out of an environment dictionary the caller injects, the way
/// every other process fact of this CLI does — the model switch of
/// ``AgentComposition/modelSource(environment:)`` and the
/// `XDG_CONFIG_HOME` of the configuration stack read the same dictionary.
/// A test therefore gives a command that writes the file and ends at
/// once, so no test opens an interactive editor and no test waits for a
/// person.
///
/// **The editor inherits the three standard streams.** An editor draws on
/// the terminal it was started from, so this launcher passes the process
/// streams through unchanged and waits for the editor to end.
enum EditorLauncher {
    /// The environment variable that names the editor.
    static let variable = "EDITOR"

    /// The status a program that succeeded ends with.
    private static let successStatus: Int32 = 0

    /// The program that resolves the editor command against `PATH`.
    ///
    /// A person names an editor with a bare word — `vi`, `nano`, `code` —
    /// far more often than with a path, and this is the one program every
    /// macOS install carries for that lookup. It passes an absolute
    /// command through unchanged.
    private static let pathResolver = URL(fileURLWithPath: "/usr/bin/env")

    /// The separator between the editor program and its own arguments.
    private static let argumentSeparator: Character = " "

    /// The editor command `environment` names.
    ///
    /// - Parameter environment: The environment to read.
    /// - Returns: The command, with any arguments the person wrote after
    ///   the program name still in it.
    /// - Throws: ``EditorNotNamedError`` when the variable is absent, or
    ///   holds nothing but space.
    static func command(in environment: [String: String]) throws -> String {
        let command = environment[variable]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !command.isEmpty else {
            throw EditorNotNamedError(variable: variable)
        }
        return command
    }

    /// Opens `file` in `command`, and waits for the editor to end.
    ///
    /// - Parameters:
    ///   - file: The file the editor opens. Its path is the last argument,
    ///     after any argument the command itself carries.
    ///   - command: The editor command, from ``command(in:)``.
    /// - Throws: The spawn error when the command cannot be run, or
    ///   ``EditorFailedError`` when the editor ends with a failure status.
    static func open(_ file: URL, with command: String) throws {
        let process = Process()
        process.executableURL = pathResolver
        process.arguments =
            command.split(separator: argumentSeparator).map(String.init) + [file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == successStatus else {
            throw EditorFailedError(command: command, status: process.terminationStatus)
        }
    }
}

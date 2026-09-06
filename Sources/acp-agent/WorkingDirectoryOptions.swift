import ArgumentParser
import Foundation

/// The `--cwd` option `run`, `config show` and `config path` share
/// (cli-plan.md §5.4, §5.10): the directory that roots the dotfolder
/// stack, and, for `run`, the session. One declaration, so the three
/// subcommands read the option, its help text and its default alike.
///
/// `acp` has no `--cwd`: the client gives the working directory with each
/// session, and a flag there would fight the protocol.
struct WorkingDirectoryOptions: ParsableArguments {
    /// The `--cwd` value, or `nil` for the process working directory.
    @Option(
        name: .customLong("cwd"),
        help:
            "The working directory. It roots the dotfolder stack, and the session of run. Default: the process working directory."
    )
    var workingDirectory: String?

    /// The directory the stack roots at: `--cwd` as a directory URL, or
    /// the process working directory when the option is absent.
    var directoryURL: URL {
        workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AgentComposition.processWorkingDirectory
    }
}

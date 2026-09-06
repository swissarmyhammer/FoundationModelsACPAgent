import Foundation

/// What a reporting subcommand writes (cli-plan.md §5.6): the report on
/// stdout, because a report is data, and each warning on stderr, so a
/// pipe never mixes the two. The subcommand builds the report as a value
/// and writes it in one place, so a test reads the value and never the
/// process streams.
struct CommandReport {
    /// The report text, newline-terminated.
    let standardOutput: String

    /// The warning lines for stderr, one message each, in load order.
    let standardErrorLines: [String]

    /// Writes the report: the text to stdout, and each warning on its own
    /// stderr line.
    func write() {
        FileHandle.standardOutput.write(Data(standardOutput.utf8))
        FileHandle.standardError.write(Data(standardErrorLines.map { $0 + "\n" }.joined().utf8))
    }
}

import Foundation
import Noora

/// The one drawing surface of the agent CLI (cli-plan.md §5.2).
///
/// Noora is the terminal design system of this CLI. It gives a spinner, a
/// progress bar, a table and color in one package. This file is the only
/// file under `Sources/acp-agent/` that imports Noora, so a later change
/// of the terminal library costs one file. Each later command that draws
/// — the download progress, `doctor` and the `--verbose` events — calls
/// this type.
///
/// The renderer vends three things and nothing more: a spinner, a
/// progress bar that takes a fraction and a byte pair, and a table of
/// rows with a status column.
///
/// **The destination and the terminal test are arguments.** The renderer
/// reads no process global. A production call site makes the renderer
/// with `FileHandle.standardError` and `isatty(STDERR_FILENO) == 1`. A
/// test makes it with a pipe and a plain boolean, so both paths run with
/// no pseudo-terminal and with no person at a screen.
///
/// **The destination is the only stream.** The renderer never writes to
/// file descriptor 1. The answer of a `run` turn owns standard output
/// (cli-plan.md §5.6), and decoration must never reach it.
///
/// **A destination that is not a terminal gets no byte.** The work
/// behind a spinner and the work behind a progress bar still runs, but
/// the renderer draws nothing. Control characters in a pipe or in a log
/// file are noise.
struct TerminalRenderer: Sendable {
    // MARK: - Types

    /// How many bytes of a download are complete, and how many bytes the
    /// download holds in total.
    struct ByteProgress: Sendable {
        /// The count of bytes that are complete.
        let completed: Int64

        /// The count of bytes of the whole download.
        let total: Int64
    }

    /// What the status column of one table row says.
    enum Status: Sendable {
        /// The check passed.
        case ok

        /// The check passed, but a person must look at it.
        case warning

        /// The check failed.
        case failure
    }

    /// One row of a table: a status, and one cell for each column after
    /// the status column.
    struct Row: Sendable {
        /// The status of the row.
        let status: Status

        /// The cells of the row, in column order.
        let cells: [String]
    }

    /// A Noora output pipeline that writes to one file handle.
    ///
    /// Noora sends every byte it draws through a pipeline. Both halves of
    /// the renderer's pipelines point at the same destination, so the
    /// renderer writes to its destination only.
    ///
    /// A write that fails is dropped. Decoration is not data: a command
    /// must not fail because a spinner could not reach a closed pipe.
    private struct FileHandlePipeline: StandardPipelining {
        /// The handle each write goes to.
        let destination: FileHandle

        /// Writes the drawn text to ``destination``.
        ///
        /// - Parameter content: The text Noora drew.
        func write(content: String) {
            try? destination.write(contentsOf: Data(content.utf8))
        }
    }

    // MARK: - Constants

    /// The mark of ``Status/ok``.
    private static let okMark = "✔︎"

    /// The mark of ``Status/warning``.
    private static let warningMark = "!"

    /// The mark of ``Status/failure``.
    private static let failureMark = "⨯"

    /// The count of cells of a progress bar.
    private static let progressBarWidth = 30

    /// The cell of a progress bar that the download filled.
    private static let filledCell = "█"

    /// The cell of a progress bar that the download did not fill yet.
    private static let emptyCell = "▒"

    /// The step between two byte units.
    private static let byteUnitStep = 1024.0

    /// The names of the byte units, from the smallest to the largest.
    private static let byteUnitNames = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// The count of percent in a whole.
    private static let percentPerWhole = 100.0

    // MARK: - Stored properties

    /// The handle that takes every byte the renderer draws.
    ///
    /// A production call site gives `FileHandle.standardError`. A test
    /// gives the write end of a pipe.
    let destination: FileHandle

    /// Whether ``destination`` is a terminal.
    ///
    /// The renderer draws when this is `true`, and draws nothing when
    /// this is `false`. A production call site gives
    /// `isatty(STDERR_FILENO) == 1`. A test gives a plain boolean.
    let isTerminal: Bool

    // MARK: - Drawing

    /// Runs `work`, and turns a spinner beside `message` while it runs.
    ///
    /// - Parameters:
    ///   - message: The text beside the spinner.
    ///   - work: The work to run.
    /// - Returns: What `work` gave back.
    /// - Throws: Whatever `work` throws.
    func spinner<Value>(
        message: String,
        work: @escaping () async throws -> Value
    ) async throws -> Value {
        guard isTerminal else { return try await work() }
        return try await step(message: message, showSpinner: true) { _ in
            try await work()
        }
    }

    /// Runs `work`, and draws a progress bar beside `message` while it
    /// runs.
    ///
    /// `work` gets a report function. Each report draws the bar again in
    /// the same place, so the bar grows where it is. A report that
    /// arrives when the destination is not a terminal does nothing.
    ///
    /// Each report carries its own text as well, because the subject of a
    /// bar changes while the bar runs: a model resolution moves from one
    /// phase to the next, and from one slot to the next. `message` is what
    /// the line says until the first report arrives.
    ///
    /// The bar goes through Noora's step channel, and not through
    /// Noora's own bar component: the step channel draws again on each
    /// report and carries the byte pair, and the bar component draws only
    /// on a timer tick and carries the fraction alone.
    ///
    /// - Parameters:
    ///   - message: The text beside the bar until the first report.
    ///   - work: The work to run. It gets a function that takes the text
    ///     beside the bar, the fraction that is complete, from 0 to 1, and
    ///     the byte pair.
    /// - Returns: What `work` gave back.
    /// - Throws: Whatever `work` throws.
    func progressBar<Value>(
        message: String,
        work: @escaping (@escaping @Sendable (String, Double, ByteProgress) -> Void) async throws
            -> Value
    ) async throws -> Value {
        guard isTerminal else { return try await work { _, _, _ in } }
        return try await step(message: message, showSpinner: false) { report in
            try await work { text, fraction, bytes in
                report(Self.progressLine(message: text, fraction: fraction, bytes: bytes))
            }
        }
    }

    /// Draws a table whose first column is a status column.
    ///
    /// - Parameters:
    ///   - statusHeader: The header of the status column.
    ///   - columnHeaders: The headers of the columns after the status
    ///     column.
    ///   - rows: The rows, each with a status and one cell for each
    ///     header in `columnHeaders`.
    func table(statusHeader: String, columnHeaders: [String], rows: [Row]) {
        guard isTerminal else { return }
        makeNoora().table(
            headers: Self.plainCells([statusHeader] + columnHeaders),
            rows: rows.map { row in
                [Self.statusCell(row.status)] + Self.plainCells(row.cells)
            })
    }

    // MARK: - Helpers

    /// The one call into Noora's step channel.
    ///
    /// A step draws a line, draws it again on each report, and closes
    /// with a completion line. The spinner and the progress bar are the
    /// same step with a different icon and a different report text.
    ///
    /// - Parameters:
    ///   - message: The first text of the step.
    ///   - showSpinner: Whether the icon turns while the task runs.
    ///   - task: The work to run. It gets a function that replaces the
    ///     text of the step.
    /// - Returns: What `task` gave back.
    /// - Throws: Whatever `task` throws.
    private func step<Value>(
        message: String,
        showSpinner: Bool,
        task: @escaping (@escaping @Sendable (String) -> Void) async throws -> Value
    ) async throws -> Value {
        try await makeNoora().progressStep(
            message: message,
            successMessage: nil,
            errorMessage: nil,
            showSpinner: showSpinner,
            task: task)
    }

    /// Makes the Noora instance that draws to ``destination``.
    ///
    /// The terminal is interactive, because the renderer builds this only
    /// when ``isTerminal`` is `true`. The signal behavior is `none`,
    /// because the CLI installs its own interrupt handler and Noora must
    /// not replace it.
    ///
    /// - Returns: The Noora instance.
    private func makeNoora() -> Noora {
        let pipeline = FileHandlePipeline(destination: destination)
        return Noora(
            terminal: Terminal(isInteractive: true, isColored: true, signalBehavior: .none),
            standardPipelines: StandardPipelines(output: pipeline, error: pipeline))
    }

    /// The status column cell of one status, in the color of the status.
    ///
    /// - Parameter status: The status of the row.
    /// - Returns: The styled cell.
    private static func statusCell(_ status: Status) -> TableCellStyle {
        switch status {
        case .ok: .success(okMark)
        case .warning: .warning(warningMark)
        case .failure: .danger(failureMark)
        }
    }

    /// Cells that carry text and no color.
    ///
    /// - Parameter texts: The texts, in column order.
    /// - Returns: One cell for each text.
    private static func plainCells(_ texts: [String]) -> [TableCellStyle] {
        texts.map { TableCellStyle.plain($0) }
    }

    /// The one line that a progress bar draws.
    ///
    /// - Parameters:
    ///   - message: The text beside the bar.
    ///   - fraction: The fraction that is complete, from 0 to 1. A value
    ///     outside that range is held at the nearest end.
    ///   - bytes: The byte pair to show after the percentage.
    /// - Returns: The line, with the message, the bar, the percentage and
    ///   the byte pair.
    private static func progressLine(
        message: String, fraction: Double, bytes: ByteProgress
    ) -> String {
        let heldFraction = min(max(fraction, 0), 1)
        let filledCount = Int((Double(progressBarWidth) * heldFraction).rounded(.down))
        let bar =
            String(repeating: filledCell, count: filledCount)
            + String(repeating: emptyCell, count: progressBarWidth - filledCount)
        let percent = Int((heldFraction * percentPerWhole).rounded(.down))
        return
            "\(message) \(bar) \(percent)% \(byteText(bytes.completed)) / \(byteText(bytes.total))"
    }

    /// A count of bytes as text, in the largest unit that holds it.
    ///
    /// The units step by 1024. A count below one kilobyte is a whole
    /// number of bytes; a larger count carries one decimal, so a bar that
    /// grows slowly still moves.
    ///
    /// `ByteCountFormatter` cannot do this: it drops the decimal of a
    /// whole count, and gives `1 MB` in each of its four count styles.
    ///
    /// - Parameter count: The count of bytes. A count below zero counts
    ///   as zero.
    /// - Returns: The text, such as `1.0 MB`.
    private static func byteText(_ count: Int64) -> String {
        var scaled = Double(max(count, 0))
        var unitIndex = 0
        while scaled >= byteUnitStep, unitIndex < byteUnitNames.count - 1 {
            scaled /= byteUnitStep
            unitIndex += 1
        }
        guard unitIndex > 0 else { return "\(Int64(scaled)) \(byteUnitNames[unitIndex])" }
        return String(format: "%.1f %@", scaled, byteUnitNames[unitIndex])
    }
}

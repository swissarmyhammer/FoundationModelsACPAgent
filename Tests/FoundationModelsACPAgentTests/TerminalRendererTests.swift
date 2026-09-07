import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import acp_agent

/// The one drawing surface of the agent CLI (cli-plan.md §5.2).
///
/// The renderer takes its destination and its terminal test as arguments,
/// so both paths run with a pipe and a plain boolean. No test needs a
/// pseudo-terminal, and no test needs a person to look at a screen.
///
/// The suite is serialized because one test points descriptor 1 at a
/// throwaway file for the length of a render. A parallel suite that wrote
/// to stdout in that window would land in the same file.
@Suite(.serialized) struct TerminalRendererTests {
    // MARK: - Constants

    /// The message the spinner and the bar carry.
    private static let message = "Resolving the profile"

    /// The completed half of the byte pair the bar reports: one mebibyte.
    private static let completedBytes: Int64 = 1_048_576

    /// The total half of the byte pair the bar reports: four mebibytes.
    private static let totalBytes: Int64 = 4_194_304

    /// The fraction that matches ``completedBytes`` over ``totalBytes``.
    private static let fraction = 0.25

    /// What the bar must show for that byte pair.
    private static let byteText = "1.0 MB / 4.0 MB"

    /// The header of the status column of the table.
    private static let statusHeader = "Status"

    /// The headers of the columns after the status column.
    private static let columnHeaders = ["Check", "Detail"]

    /// The rows of the table, one for each status the renderer draws.
    private static let rows = [
        TerminalRenderer.Row(status: .ok, cells: ["configuration", "3 layers"]),
        TerminalRenderer.Row(status: .warning, cells: ["transcripts", "no root"]),
        TerminalRenderer.Row(status: .failure, cells: ["profile", "model missing"]),
    ]

    /// The name of the one file under `Sources/acp-agent/` that may import
    /// Noora.
    private static let rendererFileName = "TerminalRenderer.swift"

    /// The import line the source test counts.
    private static let nooraImport = "import Noora"

    /// The directory the source test walks.
    private static let agentSourceDirectory = "Sources/acp-agent"

    // MARK: - Nothing is drawn when the destination is not a terminal

    /// A spinner on a pipe that is not a terminal writes no byte at all.
    @Test func theSpinnerDrawsNothingWhenTheDestinationIsNotATerminal() async throws {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(destination: capture.destination, isTerminal: false)

        try await renderer.spinner(message: Self.message) {}

        #expect(capture.bytes().isEmpty)
    }

    /// A progress bar on a pipe that is not a terminal writes no byte at
    /// all, however many times the task reports.
    @Test func theProgressBarDrawsNothingWhenTheDestinationIsNotATerminal() async throws {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(destination: capture.destination, isTerminal: false)

        try await renderer.progressBar(message: Self.message) { report in
            report(Self.fraction, Self.byteProgress)
        }

        #expect(capture.bytes().isEmpty)
    }

    /// A table on a pipe that is not a terminal writes no byte at all.
    @Test func theTableDrawsNothingWhenTheDestinationIsNotATerminal() {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(destination: capture.destination, isTerminal: false)

        renderer.table(
            statusHeader: Self.statusHeader, columnHeaders: Self.columnHeaders, rows: Self.rows)

        #expect(capture.bytes().isEmpty)
    }

    /// Drawing nothing is not doing nothing: the work behind a spinner and
    /// the work behind a bar both run when the destination is not a
    /// terminal, and the bar still takes its reports.
    @Test func theWorkRunsWhenTheDestinationIsNotATerminal() async throws {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(destination: capture.destination, isTerminal: false)

        let spun = try await renderer.spinner(message: Self.message) { "spun" }
        let reported = try await renderer.progressBar(message: Self.message) { report in
            report(Self.fraction, Self.byteProgress)
            return "reported"
        }

        #expect(spun == "spun")
        #expect(reported == "reported")
    }

    // MARK: - Something is drawn when the destination is a terminal

    /// A spinner on a pipe the renderer is told is a terminal writes a
    /// payload, and the payload names the message.
    @Test func theSpinnerDrawsToATerminalDestination() async throws {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(destination: capture.destination, isTerminal: true)

        try await renderer.spinner(message: Self.message) {}

        let drawn = capture.text()
        #expect(!drawn.isEmpty)
        #expect(drawn.contains(Self.message))
    }

    /// A progress bar on a pipe the renderer is told is a terminal writes a
    /// payload, and the payload names the byte pair the task reported.
    @Test func theProgressBarDrawsToATerminalDestination() async throws {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(destination: capture.destination, isTerminal: true)

        try await renderer.progressBar(message: Self.message) { report in
            report(Self.fraction, Self.byteProgress)
        }

        let drawn = capture.text()
        #expect(!drawn.isEmpty)
        #expect(drawn.contains(Self.byteText))
    }

    /// A table on a pipe the renderer is told is a terminal writes a
    /// payload, and the payload names the status header and every row.
    @Test func theTableDrawsToATerminalDestination() {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(destination: capture.destination, isTerminal: true)

        renderer.table(
            statusHeader: Self.statusHeader, columnHeaders: Self.columnHeaders, rows: Self.rows)

        let drawn = capture.text()
        #expect(!drawn.isEmpty)
        #expect(drawn.contains(Self.statusHeader))
        for row in Self.rows {
            for cell in row.cells {
                #expect(drawn.contains(cell))
            }
        }
    }

    // MARK: - The renderer never touches descriptor 1

    /// A full render — the spinner, the bar and the table, on a terminal
    /// destination — leaves descriptor 1 empty. The answer of a `run` turn
    /// owns stdout (cli-plan.md §5.6), and decoration must never reach it.
    @Test func aFullRenderLeavesDescriptorOneEmpty() async throws {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(destination: capture.destination, isTerminal: true)

        let onStandardOutput = try await Self.capturingStandardOutput {
            try await renderer.spinner(message: Self.message) {}
            try await renderer.progressBar(message: Self.message) { report in
                report(Self.fraction, Self.byteProgress)
            }
            renderer.table(
                statusHeader: Self.statusHeader, columnHeaders: Self.columnHeaders, rows: Self.rows)
        }

        #expect(onStandardOutput.isEmpty)
        #expect(!capture.bytes().isEmpty)
    }

    // MARK: - One file holds the import

    /// `TerminalRenderer.swift` is the only file under
    /// `Sources/acp-agent/` that imports Noora, so a later swap of the
    /// terminal library costs one file (cli-plan.md §5.2).
    @Test func theRendererIsTheOnlyFileThatImportsNoora() throws {
        let sources = try PackageRoot.directory().appendingPathComponent(
            Self.agentSourceDirectory)
        let importers = try Self.swiftFiles(under: sources)
            .filter { try String(contentsOf: $0, encoding: .utf8).contains(Self.nooraImport) }
            .map(\.lastPathComponent)
            .sorted()

        #expect(importers == [Self.rendererFileName])
    }

    // MARK: - Helpers

    /// The byte pair the bar tests report.
    private static var byteProgress: TerminalRenderer.ByteProgress {
        TerminalRenderer.ByteProgress(completed: completedBytes, total: totalBytes)
    }

    /// Every `.swift` file under `directory`, at any depth.
    ///
    /// - Parameter directory: The directory to walk.
    /// - Returns: The file URLs, in the order the walk found them.
    /// - Throws: The directory-read error.
    private static func swiftFiles(under directory: URL) throws -> [URL] {
        try FileManager.default
            .subpathsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .map { directory.appendingPathComponent($0) }
    }

    /// Runs `body` with descriptor 1 pointed at a throwaway file, and gives
    /// back the bytes that landed there.
    ///
    /// A file, and not a pipe: a full pipe buffer would block the render,
    /// and a file takes every byte and reads back at any time.
    ///
    /// - Parameter body: The work to run while descriptor 1 is captured.
    /// - Returns: The bytes descriptor 1 received.
    /// - Throws: Whatever `body` throws, or the file error.
    private static func capturingStandardOutput(
        _ body: () async throws -> Void
    ) async throws -> Data {
        let url = makeResolvedDirectory(label: "TerminalRendererTests-stdout")
            .appendingPathComponent("stdout.txt")
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }

        let saved = dup(STDOUT_FILENO)
        defer { close(saved) }
        dup2(file.fileDescriptor, STDOUT_FILENO)

        do {
            try await body()
        } catch {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
            throw error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)

        return try Data(contentsOf: url)
    }
}

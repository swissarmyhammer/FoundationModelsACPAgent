import ArgumentParser
import Darwin
import Foundation
import FoundationModelsACPAgent
import FoundationModelsExtras

extension AcpAgentCommand {
    /// `acp-agent doctor`: check that this configuration will actually
    /// work (cli-plan.md §5.12).
    ///
    /// The command runs the ``Doctorable`` components of this package
    /// through the Extras ``DoctorRunner``, renders the ``DoctorReport``,
    /// and exits 0, 1 or 5 (§5.8). The protocol, the runner and the plain
    /// renderer are Extras'; the components are this package's, and each
    /// one is a card of its own.
    ///
    /// **Two rendering paths, and this resolves a contradiction in the
    /// plans.** ``TerminalRenderer`` draws nothing when its destination is
    /// not a terminal, but the doctor plan asks for plain text in a pipe,
    /// in a stable and testable form. A silent renderer cannot give a
    /// piped table. So a terminal stderr gets the drawn table, with color
    /// and box drawing, and a stderr that is not a terminal gets the
    /// Extras plain-text rendering — plain text, no ANSI escape, still on
    /// stderr. The doctor table is the one carve-out of the
    /// silent-on-pipe rule, and the carve-out is deliberate: a diagnostic
    /// that vanishes in a pipe is useless in CI.
    ///
    /// `--json` writes the report to stdout as one JSON array, for a
    /// script. The human table never reaches stdout, and the JSON
    /// document never reaches stderr.
    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "doctor",
            abstract: "Check that this configuration will actually work.",
            discussion: """
                The table goes to stderr: it is drawn when stderr is a \
                terminal, and it is plain text with no escape sequence \
                when stderr is a pipe or a file. With --json the report \
                goes to stdout instead, as one JSON array.

                The command exits 0 when every check passed, 1 when any \
                check failed, and 5 when checks warned and none failed.
                """)

        // MARK: - Constants

        /// The header of the status column of the drawn table.
        private static let statusHeader = "Status"

        /// The headers of the columns after the status column.
        private static let columnHeaders = ["Check", "Message", "Fix"]

        /// The fix cell of a check that passed, which states no fix.
        private static let noFixText = ""

        /// The byte that ends the JSON document, so a shell prompt starts
        /// on its own line.
        private static let documentTerminator = "\n"

        // MARK: - Options

        /// The `--cwd` option (§5.10).
        @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

        /// Whether the report goes to stdout as JSON in place of the
        /// table on stderr.
        @Flag(
            name: .customLong("json"),
            help: "Write the report to stdout as one JSON array, and draw no table.")
        var asJSON = false

        // MARK: - The registry

        /// The ``Doctorable`` components this package checks.
        ///
        /// **This is the one place a later card touches.** Each card that
        /// writes checks — the profile, the sandbox, the tools, the skills
        /// — appends its own conformance here, and the command around it
        /// never changes again.
        ///
        /// The configuration, the transcripts and the tools are registered.
        /// All three read one load of `config.yaml`, which this function
        /// makes once and hands to each of them, so a `doctor` run reads
        /// the stack a single time.
        ///
        /// A component reports a failure as a ``HealthCheck`` with the
        /// `error` status, and never by throwing: `doctor` runs every
        /// check, so one broken component must not hide the rest. That is
        /// why this function does not throw. The one refusal it cannot
        /// report that way is a dotfolder name the stack rejects, and
        /// ``AgentComposition/dotfolderName`` is a compiled-in bare word,
        /// so that branch stands for a name a future edit could break and
        /// is unreachable today.
        ///
        /// - Parameters:
        ///   - workingDirectory: The directory `--cwd` names, which roots
        ///     the dotfolder stack the checks read.
        ///   - environment: The environment the checks read, above all
        ///     `XDG_CONFIG_HOME`.
        ///   - prober: How ``ToolsDoctor`` reaches the world. The default
        ///     starts the real seatbelt canary and connects each real MCP
        ///     server; a test injects a stub, so no unit test spawns a
        ///     process.
        /// - Returns: The components, in the order the report lists them.
        static func components(
            workingDirectory: URL, environment: [String: String],
            prober: any ToolsProber = SystemToolsProber()
        ) -> [any Doctorable] {
            guard
                let loader = try? AgentComposition.makeConfigurationLoader(
                    workingDirectory: workingDirectory, environment: environment)
            else {
                return []
            }
            let outcome = ConfigurationLoadOutcome(of: loader)
            return [
                ConfigurationDoctor(stack: loader.stack, outcome: outcome),
                TranscriptsDoctor(
                    configuration: outcome.configuration, stack: loader.stack,
                    name: loader.name, workingDirectory: workingDirectory),
                ToolsDoctor(
                    configuration: outcome.configuration, workingDirectory: workingDirectory,
                    prober: prober),
            ]
        }

        // MARK: - Running

        mutating func run() async throws {
            let report = await DoctorRunner(
                components: Self.components(
                    workingDirectory: workingDirectoryOptions.directoryURL,
                    environment: ProcessInfo.processInfo.environment)
            ).run()
            try Self.write(
                report, asJSON: asJSON,
                renderer: TerminalRenderer(
                    destination: .standardError, isTerminal: isatty(STDERR_FILENO) == 1),
                standardOutput: .standardOutput)
            let code = AgentExitCode(doctor: report)
            guard code == .success else { throw code.parserError }
        }

        // MARK: - Rendering

        /// Writes `report` on the one path the flags and the destination
        /// select.
        ///
        /// **Both destinations are arguments, so a test injects a pipe for
        /// each and reads back what landed where.** The three paths are
        /// exclusive: the JSON document goes to `standardOutput` alone,
        /// and each of the two table renderings goes to the renderer's
        /// destination alone.
        ///
        /// - Parameters:
        ///   - report: The report the runner built.
        ///   - asJSON: Whether the report goes to `standardOutput` as
        ///     JSON in place of the table.
        ///   - renderer: The renderer of the human table. It carries the
        ///     destination of the table and the terminal test that picks
        ///     the drawn path or the plain path.
        ///   - standardOutput: The handle the JSON document goes to.
        /// - Throws: The encoding error of the JSON document, or the
        ///   write error of either handle.
        static func write(
            _ report: DoctorReport, asJSON: Bool, renderer: TerminalRenderer,
            standardOutput: FileHandle
        ) throws {
            guard !asJSON else {
                try standardOutput.write(contentsOf: try jsonDocument(of: report))
                return
            }
            guard renderer.isTerminal else {
                try PlainTextDoctorRenderer().write(report, to: renderer.destination)
                return
            }
            renderer.table(
                statusHeader: statusHeader, columnHeaders: columnHeaders,
                rows: report.checks.map(row(for:)))
        }

        /// The `--json` document: the report as one JSON array, pretty, and
        /// newline-terminated.
        ///
        /// - Parameter report: The report to encode.
        /// - Returns: The bytes to write to stdout.
        /// - Throws: The encoding error.
        private static func jsonDocument(of report: DoctorReport) throws -> Data {
            try report.jsonData(prettyPrinted: true) + Data(documentTerminator.utf8)
        }

        /// The drawn row of one check: its status, its name, its message,
        /// and the fix of a check that did not pass.
        ///
        /// - Parameter check: The check to draw.
        /// - Returns: The row, with one cell for each of ``columnHeaders``.
        private static func row(for check: HealthCheck) -> TerminalRenderer.Row {
            TerminalRenderer.Row(
                status: status(of: check.status),
                cells: [check.name, check.message, check.fix ?? noFixText])
        }

        /// The drawing status of one health status.
        ///
        /// **The switch is total, and it declares no `default`.** A status
        /// Extras gains later must be drawn on purpose, and the compiler
        /// is what asks for that.
        ///
        /// - Parameter health: The status the check reported.
        /// - Returns: The status the renderer draws.
        private static func status(of health: HealthStatus) -> TerminalRenderer.Status {
            switch health {
            case .ok: .ok
            case .warning: .warning
            case .error: .failure
            }
        }
    }
}

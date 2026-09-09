import ArgumentParser
import Foundation
import FoundationModelsExtras
import Testing

@testable import acp_agent

/// `acp-agent doctor` (cli-plan.md §5.12): the command runs the
/// ``Doctorable`` components of this package through the Extras
/// ``DoctorRunner``, renders the report, and exits 0, 1 or 5.
///
/// The checks themselves are three later cards, so every component here is
/// a stub. What this suite proves is the plumbing: the exit code of each
/// status, the two rendering paths, and which stream each one writes to.
///
/// Both streams are pipes, so no test needs a pseudo-terminal and no test
/// writes to the process streams.
struct DoctorCommandTests {
    // MARK: - Constants

    /// The start of every ANSI escape sequence.
    private static let ansiEscape = "\u{1B}["

    /// The category every stub component reports under.
    private static let stubCategory = "stub"

    /// The name of the check that passes.
    private static let okCheckName = "configuration"

    /// The name of the check that warns.
    private static let warningCheckName = "transcripts"

    /// The name of the check that fails.
    private static let errorCheckName = "profile"

    /// The message of the check that passes.
    private static let okMessage = "three layers load"

    /// The message of the check that warns.
    private static let warningMessage = "no transcript root"

    /// The message of the check that fails.
    private static let errorMessage = "the model id is not well formed"

    /// The fix of a check that is not `ok`.
    private static let fixText = "acp-agent config init"

    /// The `--cwd` value of the parsing test.
    private static let projectPath = "/tmp/project"

    // MARK: - Fixtures

    /// A component that reports the checks it was made with.
    private struct StubComponent: Doctorable {
        /// The name the runner reports the component under.
        let doctorName: String

        /// The category the component reports under.
        let doctorCategory = DoctorCommandTests.stubCategory

        /// The checks ``runHealthChecks()`` gives back.
        let checks: [HealthCheck]

        func runHealthChecks() async -> [HealthCheck] {
            checks
        }
    }

    /// The check that passes.
    private static var okCheck: HealthCheck {
        .ok(name: okCheckName, message: okMessage, category: stubCategory)
    }

    /// The check that warns.
    private static var warningCheck: HealthCheck {
        .warning(
            name: warningCheckName, message: warningMessage, fix: fixText, category: stubCategory)
    }

    /// The check that fails.
    private static var errorCheck: HealthCheck {
        .error(name: errorCheckName, message: errorMessage, fix: fixText, category: stubCategory)
    }

    /// The report of one stub component that reports `checks`.
    ///
    /// - Parameter checks: The checks the component reports.
    /// - Returns: The report the runner built.
    private static func report(of checks: [HealthCheck]) async -> DoctorReport {
        await DoctorRunner(
            components: [StubComponent(doctorName: stubCategory, checks: checks)]
        ).run()
    }

    /// A pipe for each stream the command writes to, and the one call that
    /// writes a report into them.
    ///
    /// Both streams are pipes, so a test reads back what landed on each
    /// one and no test touches the process streams.
    private struct StreamCapture {
        /// The pipe that stands for stderr, which takes the table.
        let standardError = TerminalCapture()

        /// The pipe that stands for stdout, which takes the JSON.
        let standardOutput = TerminalCapture()

        /// Writes `report` through the command onto the two pipes.
        ///
        /// - Parameters:
        ///   - report: The report to write.
        ///   - asJSON: Whether the report goes to the stdout pipe as JSON.
        ///   - isTerminal: Whether the stderr pipe counts as a terminal,
        ///     which picks the drawn path or the plain path.
        /// - Throws: Whatever the command's write throws.
        func write(_ report: DoctorReport, asJSON: Bool, isTerminal: Bool) throws {
            try AcpAgentCommand.Doctor.write(
                report, asJSON: asJSON,
                renderer: TerminalRenderer(
                    destination: standardError.destination, isTerminal: isTerminal),
                standardOutput: standardOutput.destination)
        }
    }

    // MARK: - The registry

    /// The registry states an empty component list: this card owns the
    /// command, and each later card appends its own conformance, so the
    /// command never changes again.
    @Test func theRegistryStatesAnEmptyComponentList() {
        let components = AcpAgentCommand.Doctor.components(
            workingDirectory: URL(fileURLWithPath: Self.projectPath, isDirectory: true),
            environment: [:])

        #expect(components.isEmpty)
    }

    /// With no component the report holds no check, it exits 0, and the
    /// plain rendering of it is empty.
    @Test func anEmptyComponentListExitsZeroWithAnEmptyReport() async {
        let report = await DoctorRunner(components: []).run()

        #expect(report.checks.isEmpty)
        #expect(AgentExitCode(doctor: report) == .success)
        #expect(PlainTextDoctorRenderer().render(report).isEmpty)
    }

    /// A report with no check renders on both paths and writes nothing to
    /// stdout: an empty registry is a whole answer, and neither path may
    /// fail on it.
    ///
    /// - Parameter isTerminal: Whether the destination is a terminal,
    ///   which picks the drawn path or the plain path.
    @Test(arguments: [true, false])
    func anEmptyReportRendersOnBothPaths(isTerminal: Bool) async throws {
        let capture = StreamCapture()
        let report = await DoctorRunner(components: []).run()

        try capture.write(report, asJSON: false, isTerminal: isTerminal)

        #expect(capture.standardOutput.bytes().isEmpty)
    }

    // MARK: - The three exit codes

    /// Checks that all pass exit 0.
    @Test func checksThatAllPassExitZero() async {
        let report = await Self.report(of: [Self.okCheck])

        #expect(AgentExitCode(doctor: report) == .success)
        #expect(AgentExitCode(doctor: report).rawValue == report.exitCode)
    }

    /// One check that fails exits 1, even beside a warning and a pass.
    @Test func aCheckThatFailsExitsOne() async {
        let report = await Self.report(of: [Self.okCheck, Self.warningCheck, Self.errorCheck])

        #expect(AgentExitCode(doctor: report) == .error)
        #expect(AgentExitCode(doctor: report).rawValue == report.exitCode)
    }

    /// Warnings with no failure exit 5, which is the row `doctor` owns.
    @Test func warningsWithNoFailureExitFive() async {
        let report = await Self.report(of: [Self.okCheck, Self.warningCheck])

        #expect(AgentExitCode(doctor: report) == .doctorWarnings)
        #expect(AgentExitCode(doctor: report).rawValue == report.exitCode)
    }

    // MARK: - The two rendering paths

    /// A destination that is not a terminal gets the Extras plain-text
    /// rendering: the bytes are there, and they hold no ANSI escape.
    ///
    /// The doctor table is the one carve-out of the silent-on-pipe rule of
    /// ``TerminalRenderer``. A diagnostic that vanishes in a pipe is
    /// useless in CI.
    @Test func aDestinationThatIsNotATerminalGetsPlainText() async throws {
        let capture = StreamCapture()
        let report = await Self.report(of: [Self.okCheck, Self.errorCheck])

        try capture.write(report, asJSON: false, isTerminal: false)

        let drawn = capture.standardError.text()
        #expect(!drawn.isEmpty)
        #expect(!drawn.contains(Self.ansiEscape))
        #expect(drawn.contains(Self.errorCheckName))
        #expect(drawn.contains(Self.errorMessage))
        #expect(drawn.contains(Self.fixText))
        #expect(capture.standardOutput.bytes().isEmpty)
    }

    /// A destination that is a terminal gets the table the
    /// ``TerminalRenderer`` draws, with each check in it.
    @Test func aTerminalDestinationGetsTheDrawnTable() async throws {
        let capture = StreamCapture()
        let report = await Self.report(of: [Self.okCheck, Self.warningCheck])

        try capture.write(report, asJSON: false, isTerminal: true)

        let drawn = capture.standardError.text()
        #expect(!drawn.isEmpty)
        #expect(drawn.contains(Self.okCheckName))
        #expect(drawn.contains(Self.warningCheckName))
        #expect(drawn.contains(Self.warningMessage))
        #expect(capture.standardOutput.bytes().isEmpty)
    }

    // MARK: - Which stream each rendering goes to

    /// `--json` writes the report to stdout, and writes nothing to the
    /// human stream: the two are the reverse of each other.
    @Test func jsonGoesToStdoutAndTheTableDoesNot() async throws {
        let capture = StreamCapture()
        let report = await Self.report(of: [Self.okCheck, Self.errorCheck])

        try capture.write(report, asJSON: true, isTerminal: true)

        #expect(!capture.standardOutput.bytes().isEmpty)
        #expect(capture.standardError.bytes().isEmpty)
    }

    /// The `--json` document decodes to the same checks the report holds.
    @Test func theJSONDecodesToTheSameChecks() async throws {
        let capture = StreamCapture()
        let report = await Self.report(of: [Self.okCheck, Self.warningCheck, Self.errorCheck])

        try capture.write(report, asJSON: true, isTerminal: false)

        let decoded = try JSONDecoder().decode(
            DoctorReport.self, from: capture.standardOutput.bytes())
        #expect(decoded.checks == report.checks)
    }

    // MARK: - The command line

    /// `doctor` takes `--cwd` and `--json`, and both default to off.
    @Test func theCommandTakesCwdAndJSON() throws {
        let plain = try #require(
            try AcpAgentCommand.parseAsRoot(["doctor"]) as? AcpAgentCommand.Doctor)
        let flagged = try #require(
            try AcpAgentCommand.parseAsRoot(["doctor", "--json", "--cwd", Self.projectPath])
                as? AcpAgentCommand.Doctor)

        #expect(!plain.asJSON)
        #expect(plain.workingDirectoryOptions.workingDirectory == nil)
        #expect(flagged.asJSON)
        #expect(flagged.workingDirectoryOptions.workingDirectory == Self.projectPath)
    }
}

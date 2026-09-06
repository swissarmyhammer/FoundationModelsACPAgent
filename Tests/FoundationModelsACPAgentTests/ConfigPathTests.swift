import ArgumentParser
import Foundation
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `acp-agent config path` (cli-plan.md §5.11): one line per layer with
/// its path and an exists mark, plain text on stdout, no renderer and no
/// ANSI escape. Each test parses the real arguments and builds the
/// report in process.
struct ConfigPathTests {
    // MARK: - Constants

    /// The mark of a layer directory that is on disk.
    private static let existsMark = "exists"

    /// The mark of a layer directory that is not on disk.
    private static let missingMark = "missing"

    /// The start of every ANSI escape sequence.
    private static let ansiEscape = "\u{1B}["

    /// The number of rows: builtin, user and project.
    private static let layerRowCount = 3

    /// The index of the builtin row.
    private static let builtinRow = 0

    /// The index of the user row.
    private static let userRow = 1

    /// The index of the project row.
    private static let projectRow = 2

    // MARK: - Helpers

    /// Parses `config path` over `fixture`'s workspace and builds its
    /// report over `fixture`'s environment.
    ///
    /// - Parameter fixture: The two-layer tree the report describes.
    /// - Returns: The report.
    /// - Throws: The parse error.
    private static func report(in fixture: ConfigCommandFixture) throws -> CommandReport {
        let path = try #require(
            try AcpAgentCommand.parseAsRoot(["config", "path", "--cwd", fixture.workspace.path])
                as? AcpAgentCommand.Config.Path)
        return try path.report(environment: fixture.environment)
    }

    /// The report lines, without the terminating newline.
    private static func lines(of report: CommandReport) -> [String] {
        report.standardOutput.split(separator: "\n").map(String.init)
    }

    // MARK: - The report

    /// With only the project layer on disk, the three rows name their
    /// layer and path, the project row is marked `exists`, the user row
    /// `missing`, and the builtin row says it is in code.
    @Test func theThreeLayersCarryTheRightMarks() throws {
        let fixture = ConfigCommandFixture(label: "ConfigPathTests-marks")
        try FileManager.default.createDirectory(
            at: fixture.projectDirectory, withIntermediateDirectories: true)

        let report = try Self.report(in: fixture)

        let lines = Self.lines(of: report)
        #expect(lines.count == Self.layerRowCount)
        #expect(lines[Self.builtinRow].hasPrefix("builtin"))
        #expect(!lines[Self.builtinRow].contains(Self.existsMark))
        #expect(!lines[Self.builtinRow].contains(Self.missingMark))
        #expect(lines[Self.userRow].hasPrefix("user"))
        #expect(lines[Self.userRow].contains(fixture.userDirectory.path))
        #expect(lines[Self.userRow].hasSuffix(Self.missingMark))
        #expect(lines[Self.projectRow].hasPrefix("project"))
        #expect(lines[Self.projectRow].contains(fixture.projectDirectory.path))
        #expect(lines[Self.projectRow].hasSuffix(Self.existsMark))
        #expect(report.standardErrorLines.isEmpty)
    }

    /// A user layer on disk is marked `exists`, and a project layer that
    /// is absent is marked `missing`: the marks follow the disk, not the
    /// row.
    @Test func theMarksFollowTheDisk() throws {
        let fixture = ConfigCommandFixture(label: "ConfigPathTests-user")
        try FileManager.default.createDirectory(
            at: fixture.userDirectory, withIntermediateDirectories: true)

        let report = try Self.report(in: fixture)

        let lines = Self.lines(of: report)
        #expect(lines[Self.userRow].hasSuffix(Self.existsMark))
        #expect(lines[Self.projectRow].hasSuffix(Self.missingMark))
    }

    /// The output is plain text: it holds no ANSI escape.
    @Test func theOutputHoldsNoANSIEscape() throws {
        let fixture = ConfigCommandFixture(label: "ConfigPathTests-ansi")

        let report = try Self.report(in: fixture)

        #expect(!report.standardOutput.contains(Self.ansiEscape))
        #expect(report.standardOutput.hasSuffix("\n"))
    }

    /// `--cwd` roots the project row: the row names the given directory.
    @Test func cwdRootsTheProjectRow() throws {
        let fixture = ConfigCommandFixture(label: "ConfigPathTests-cwd")

        let report = try Self.report(in: fixture)

        let projectRow = try #require(Self.lines(of: report).last)
        #expect(projectRow.contains(fixture.workspace.path))
    }
}

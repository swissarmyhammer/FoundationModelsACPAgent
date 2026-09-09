import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `ConfigurationDoctor` (cli-plan.md §5.12, row 1): the configuration
/// loads, every loader warning is listed, and each layer path of §5.10 is
/// reported as it stands on disk.
///
/// Each test drives the component over a throwaway two-layer stack, so no
/// test reads the real home directory.
struct ConfigurationDoctorTests {
    // MARK: - Constants

    /// The permissions of a layer directory that cannot be read.
    private static let unreadablePermissions = NSNumber(value: 0o000)

    /// The permissions a test puts back, so the directory can be removed.
    private static let ownerPermissions = NSNumber(value: 0o700)

    /// A top-level section no schema section is named after.
    private static let unknownSectionName = "surprise"

    /// A key the `recording` section does not decode.
    private static let unknownKeyName = "loudness"

    /// The command a permission fix names.
    private static let permissionCommand = "chmod"

    /// The command a load failure names.
    private static let loadFixCommand = "config show"

    /// The number of findings a test that expects exactly one gets.
    private static let oneFinding = 1

    // MARK: - Helpers

    /// The component over `fixture`'s stack, with the one load it reports.
    ///
    /// - Parameter fixture: The two-layer tree the component reads.
    /// - Returns: The component.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
    private static func doctor(in fixture: ConfigCommandFixture) throws -> ConfigurationDoctor {
        let loader = try AgentComposition.makeConfigurationLoader(
            workingDirectory: fixture.workspace, environment: fixture.environment)
        return ConfigurationDoctor(
            stack: loader.stack, outcome: ConfigurationLoadOutcome(of: loader))
    }

    /// The findings the component over `fixture` reports.
    ///
    /// - Parameter fixture: The two-layer tree the component reads.
    /// - Returns: The findings, in the order the component reports them.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
    private static func checks(in fixture: ConfigCommandFixture) async throws -> [HealthCheck] {
        let component = try doctor(in: fixture)
        return await component.runHealthChecks()
    }

    /// The findings of `checks` that carry `status`.
    ///
    /// - Parameters:
    ///   - status: The status to keep.
    ///   - checks: The findings to filter.
    /// - Returns: The findings that carry `status`.
    private static func findings(
        _ status: HealthStatus, in checks: [HealthCheck]
    ) -> [HealthCheck] {
        checks.filter { $0.status == status }
    }

    /// Sets the permissions of one directory.
    ///
    /// - Parameters:
    ///   - permissions: The POSIX permissions to set.
    ///   - directory: The directory to set them on.
    /// - Throws: The attribute-write error.
    private static func setPermissions(_ permissions: NSNumber, of directory: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: directory.path)
    }

    // MARK: - The load

    /// A stack with no file in any layer passes every check: the builtin
    /// defaults are the whole configuration, and a missing layer directory
    /// is what a fresh install looks like.
    @Test func aStackWithNoFileGivesOnlyPassingChecks() async throws {
        let fixture = ConfigCommandFixture(label: "ConfigurationDoctorTests-empty")

        let checks = try await Self.checks(in: fixture)

        #expect(!checks.isEmpty)
        #expect(checks.allSatisfy { $0.status == .ok })
    }

    /// An unknown key inside a known section fails the load, so the
    /// component reports one `.error` that carries the reason and names
    /// `acp-agent config show`.
    @Test func anUnknownKeyInAKnownSectionGivesOneError() async throws {
        let fixture = ConfigCommandFixture(label: "ConfigurationDoctorTests-key")
        try fixture.writeProjectConfig("recording:\n  \(Self.unknownKeyName): full\n")

        let checks = try await Self.checks(in: fixture)

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        let fix = try #require(failure.fix)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(Self.unknownKeyName))
        #expect(fix.contains(Self.loadFixCommand))
    }

    // MARK: - The warnings

    /// An unknown top-level section is a warning the loader returns, so the
    /// component reports one `.warning` whose message names the section and
    /// whose fix names the section and the file.
    @Test func anUnknownSectionGivesOneWarningThatNamesIt() async throws {
        let fixture = ConfigCommandFixture(label: "ConfigurationDoctorTests-section")
        try fixture.writeProjectConfig("\(Self.unknownSectionName):\n  key: yes\n")

        let checks = try await Self.checks(in: fixture)

        let warnings = Self.findings(.warning, in: checks)
        let warning = try #require(warnings.first)
        let fix = try #require(warning.fix)
        #expect(warnings.count == Self.oneFinding)
        #expect(warning.message.contains(Self.unknownSectionName))
        #expect(fix.contains(Self.unknownSectionName))
        #expect(fix.contains(ConfigurationLoader.configFileName))
        #expect(Self.findings(.error, in: checks).isEmpty)
    }

    // MARK: - The layer paths

    /// A layer directory that is on disk and can be read and written
    /// passes, and its finding names the path.
    @Test func aLayerOnDiskPassesAndNamesItsPath() async throws {
        let fixture = ConfigCommandFixture(label: "ConfigurationDoctorTests-onDisk")
        try FileManager.default.createDirectory(
            at: fixture.projectDirectory, withIntermediateDirectories: true)

        let checks = try await Self.checks(in: fixture)

        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(checks.contains { $0.message.contains(fixture.projectDirectory.path) })
    }

    /// A layer directory that cannot be read is one `.error` whose fix is a
    /// `chmod` command that names the path.
    @Test func anUnreadableLayerGivesAnErrorWithAChmodFix() async throws {
        let fixture = ConfigCommandFixture(label: "ConfigurationDoctorTests-unreadable")
        try FileManager.default.createDirectory(
            at: fixture.projectDirectory, withIntermediateDirectories: true)
        try Self.setPermissions(Self.unreadablePermissions, of: fixture.projectDirectory)

        let checks = try await Self.checks(in: fixture)
        try Self.setPermissions(Self.ownerPermissions, of: fixture.projectDirectory)

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        let fix = try #require(failure.fix)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(fixture.projectDirectory.path))
        #expect(fix.contains(Self.permissionCommand))
        #expect(fix.contains(fixture.projectDirectory.path))
    }
}

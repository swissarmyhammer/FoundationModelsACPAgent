import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `TranscriptsDoctor` (cli-plan.md §5.12, row 3): the resolved transcript
/// directory exists, or its parent can be written. With
/// `recording.level: off` the component stays silent, because nothing will
/// write there.
///
/// Each test drives the component over a throwaway two-layer stack, so no
/// test reads the real home directory.
struct TranscriptsDoctorTests {
    // MARK: - Constants

    /// The permissions of a directory that can be read but not written.
    private static let readOnlyPermissions = NSNumber(value: 0o500)

    /// The permissions a test puts back, so the directory can be removed.
    private static let ownerPermissions = NSNumber(value: 0o700)

    /// The configuration key a transcripts fix names.
    private static let locationKey = "transcripts.location"

    /// The number of findings a test that expects exactly one gets.
    private static let oneFinding = 1

    // MARK: - Helpers

    /// The component over `fixture`'s stack, with the configuration the one
    /// load resolved.
    ///
    /// - Parameter fixture: The two-layer tree the component reads.
    /// - Returns: The component.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
    private static func doctor(in fixture: ConfigCommandFixture) throws -> TranscriptsDoctor {
        let loader = try AgentComposition.makeConfigurationLoader(
            workingDirectory: fixture.workspace, environment: fixture.environment)
        return TranscriptsDoctor(
            configuration: ConfigurationLoadOutcome(of: loader).configuration,
            stack: loader.stack, name: loader.name, workingDirectory: fixture.workspace)
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

    // MARK: - The recording root

    /// The default location is the project dotfolder, which is not on disk
    /// after an install. The workspace above it can be written, so the
    /// directory can be created and the check passes.
    @Test func aWritableParentPasses() async throws {
        let fixture = ConfigCommandFixture(label: "TranscriptsDoctorTests-writable")

        let component = try Self.doctor(in: fixture)
        let checks = await component.runHealthChecks()

        #expect(!checks.isEmpty)
        #expect(checks.allSatisfy { $0.status == .ok })
    }

    /// A transcripts root under a directory that cannot be written is one
    /// `.error`, and its fix names the `transcripts.location` key.
    @Test func anUnwritableParentGivesAnErrorThatNamesTheLocationKey() async throws {
        let fixture = ConfigCommandFixture(label: "TranscriptsDoctorTests-readOnly")
        let parent = makeResolvedDirectory(label: "TranscriptsDoctorTests-parent")
        let root = parent.appendingPathComponent(
            TranscriptLocation.transcriptsDirectoryName, isDirectory: true)
        try fixture.writeProjectConfig("transcripts:\n  location: \(root.path)\n")
        try Self.setPermissions(Self.readOnlyPermissions, of: parent)

        let component = try Self.doctor(in: fixture)
        let checks = await component.runHealthChecks()
        try Self.setPermissions(Self.ownerPermissions, of: parent)

        let errors = checks.filter { $0.status == .error }
        let failure = try #require(errors.first)
        let fix = try #require(failure.fix)
        #expect(errors.count == Self.oneFinding)
        #expect(fix.contains(Self.locationKey))
    }

    // MARK: - Applicability

    /// With `recording.level: off` nothing is recorded, so the component
    /// does not apply and the runner gathers no finding from it.
    @Test func recordingOffMakesTheComponentContributeNothing() async throws {
        let fixture = ConfigCommandFixture(label: "TranscriptsDoctorTests-off")
        try fixture.writeProjectConfig("recording:\n  level: off\n")

        let component = try Self.doctor(in: fixture)
        let report = await DoctorRunner(components: [component]).run()

        #expect(!component.isApplicable)
        #expect(report.checks.isEmpty)
    }
}

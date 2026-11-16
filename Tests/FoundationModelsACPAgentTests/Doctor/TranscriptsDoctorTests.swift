import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `TranscriptsDoctor` (cli-plan.md §5.12, row 3): the transcript directory
/// of the project exists, or its parent can be written (D187: the
/// transcripts are always in the project).
///
/// Each test drives the component over a throwaway workspace, so no test
/// reads the real home directory.
struct TranscriptsDoctorTests {
  // MARK: - Constants

  /// The permissions of a directory that can be read but not written.
  private static let readOnlyPermissions = NSNumber(value: 0o500)

  // MARK: - Helpers

  /// The component over the workspace of `fixture`.
  ///
  /// - Parameter fixture: The two-layer tree the component reads.
  /// - Returns: The component.
  /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
  private static func doctor(in fixture: ConfigCommandFixture) throws -> TranscriptsDoctor {
    let loader = try AgentComposition.makeConfigurationLoader(
      workingDirectory: fixture.workspace, environment: fixture.environment)
    return TranscriptsDoctor(name: loader.name, workingDirectory: fixture.workspace)
  }

  // MARK: - The recording root

  /// The project dotfolder is not on disk after an install. The workspace
  /// above it can be written, so the directory can be created and the
  /// check passes.
  @Test func aWritableParentPasses() async throws {
    let fixture = ConfigCommandFixture(label: "TranscriptsDoctorTests-writable")

    let component = try Self.doctor(in: fixture)
    let checks = await component.runHealthChecks()

    #expect(!checks.isEmpty)
    #expect(checks.allSatisfy { $0.status == .ok })
  }

  /// A project whose dotfolder cannot be written is one `.error`, and its
  /// fix names the folder to make writable.
  @Test func anUnwritableProjectGivesAnErrorThatNamesTheFolder() async throws {
    let fixture = ConfigCommandFixture(label: "TranscriptsDoctorTests-readOnly")
    let dotfolder = fixture.projectDirectory
    try FileManager.default.createDirectory(at: dotfolder, withIntermediateDirectories: true)
    try setPermissions(Self.readOnlyPermissions, of: dotfolder)

    let component = try Self.doctor(in: fixture)
    let checks = await component.runHealthChecks()
    try setPermissions(ownerOnlyPermissions, of: dotfolder)

    let failure = try checks.singleFinding(.error)
    let fix = try #require(failure.fix)
    #expect(fix.contains(dotfolder.standardizedFileURL.path))
  }

  /// An old `recording.level: off` does not turn the transcripts off, so
  /// the component still applies and reports its check.
  @Test func anOldRecordingOffKeyDoesNotSilenceTheCheck() async throws {
    let fixture = ConfigCommandFixture(label: "TranscriptsDoctorTests-off")
    try fixture.writeProjectConfig("recording:\n  level: off\n")

    let component = try Self.doctor(in: fixture)
    let report = await DoctorRunner(components: [component]).run()

    #expect(component.isApplicable)
    #expect(!report.checks.isEmpty)
  }
}

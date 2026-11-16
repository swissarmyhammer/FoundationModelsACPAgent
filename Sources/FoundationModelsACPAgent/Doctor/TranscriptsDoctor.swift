import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The `doctor` component of the transcripts (cli-plan.md §5.12, row 3):
/// the recording root of the project exists, or the nearest directory
/// above it can be written, so Router can create it.
///
/// Each session records its full transcript in its project, at
/// `<cwd>/.<name>/transcripts/` (D187). No setting moves the transcripts
/// or turns them off, so the component always applies.
///
/// The component reads no process environment, so a test drives it over a
/// temporary working directory.
public struct TranscriptsDoctor: Doctorable {
  // MARK: - Constants

  /// The group every finding of this component belongs to.
  public static let category = "transcripts"

  /// The one check this component states.
  private static let checkName = "the transcripts directory"

  /// What stands at the recording root, for the message of a path that a
  /// file already blocks.
  private static let directorySubject = "transcripts directory"

  // MARK: - Stored state

  /// The dotfolder name, which names the project dotfolder.
  private let name: DotfolderName

  /// The session working directory, which roots the recording root.
  private let workingDirectory: URL

  // MARK: - Doctorable

  /// What this component is called in the doctor report.
  public let doctorName = TranscriptsDoctor.category

  /// The group its findings belong to.
  public let doctorCategory = TranscriptsDoctor.category

  /// Makes the component over one project.
  ///
  /// - Parameters:
  ///   - name: The dotfolder name.
  ///   - workingDirectory: The session working directory.
  public init(name: DotfolderName, workingDirectory: URL) {
    self.name = name
    self.workingDirectory = workingDirectory
  }

  /// Reports the one finding of the recording root.
  ///
  /// - Returns: That finding.
  public func runHealthChecks() async -> [HealthCheck] {
    [Self.check(of: TranscriptRoot.recordingRoot(workingDirectory: workingDirectory, name: name))]
  }

  /// The finding of one recording root: it exists and can be written, or
  /// the nearest directory above it can be written, so Router creates it.
  ///
  /// - Parameter root: The recording root.
  /// - Returns: A pass, or the failure that says why the directory cannot
  ///   be used.
  private static func check(of root: URL) -> HealthCheck {
    WritableDirectoryCheck.check(
      of: root, name: checkName, subject: directorySubject, category: category,
      fix: fix(naming:))
  }

  /// The fix of a recording root that cannot be used: make the directory
  /// writable.
  ///
  /// - Parameter directory: The directory that stands in the way.
  /// - Returns: The fix text.
  private static func fix(naming directory: URL) -> String {
    "make \(directory.path) writable, so each session can record its transcript in the project"
  }
}

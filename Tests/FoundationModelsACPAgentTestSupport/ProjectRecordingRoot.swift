import Foundation
import FoundationModelsACPAgent

/// The `project` recording root of one working directory (plan.md §4.1):
/// `<workspace>/.<name>/transcripts/`.
///
/// This calls the production API, and it never builds the path again. A
/// test that writes the path itself can agree with the code today and
/// disagree with it tomorrow, and then the test reads an empty directory
/// and reports a recorder that does not write. The one construction is
/// `TranscriptLocation.project.recordingRoot(...)`, and this is the one
/// door onto it.
///
/// The function is in the shared support product because two targets
/// need it: the unit suites of the root package, and the tier-3 suites
/// of the `IntegrationTests` package.
///
/// - Parameters:
///   - workspace: The session working directory.
///   - name: The dotfolder name the project layer roots under.
/// - Returns: The recording root.
/// - Throws: `DotfolderNameError` when `name` is refused.
public func projectRecordingRoot(of workspace: URL, dotfolderName name: String) throws -> URL {
    TranscriptLocation.project.recordingRoot(
        workingDirectory: workspace,
        name: try DotfolderName(name),
        userDirectory: workspace)
}

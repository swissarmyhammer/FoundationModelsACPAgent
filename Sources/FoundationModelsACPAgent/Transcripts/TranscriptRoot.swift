import Foundation

/// The recording root of a project (D187). A transcript is project
/// context: it goes with the repository, so the agent always keeps the
/// context of a project. Each session records its full transcript at
/// `<workingDirectory>/.<name>/transcripts/<sessionId>/`; no setting moves
/// the transcripts or turns them off.
public enum TranscriptRoot {
  /// The directory name every recording root ends in.
  public static let transcriptsDirectoryName = "transcripts"

  /// The recording root of a working directory:
  /// `<workingDirectory>/.<name>/transcripts/`. It is the directory that
  /// `makeSession(recordingRoot:)` receives; Router then records each
  /// session to `<root>/<sessionId>/`.
  ///
  /// - Parameters:
  ///   - workingDirectory: The session working directory (absolute).
  ///   - name: The validated dotfolder name; the project dotfolder is
  ///     `.<name>`.
  /// - Returns: The recording root.
  public static func recordingRoot(workingDirectory: URL, name: DotfolderName) -> URL {
    workingDirectory
      .appendingPathComponent(".\(name.rawValue)", isDirectory: true)
      .appendingPathComponent(transcriptsDirectoryName, isDirectory: true)
  }
}

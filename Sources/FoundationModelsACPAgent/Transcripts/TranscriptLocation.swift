import Foundation

/// Recording-root resolution for `transcripts.location` (plan.md §4.1).
/// The resolved root is the directory `makeSession(recordingRoot:)`
/// receives; Router then records each session to `<root>/<sessionId>/`.
extension TranscriptLocation {
    /// The directory name every recording root ends in.
    public static let transcriptsDirectoryName = "transcripts"

    /// The character the slug substitutes for each unsafe one.
    private static let slugSeparator: Character = "-"

    /// The slug that stands for one project under the shared `home` root
    /// (plan.md §4.1): the absolute working directory path with each
    /// character that is not a letter or a digit replaced by `-`, so
    /// `/Users/dev/example` becomes `-Users-dev-example`. The scheme
    /// applies only to `home`; a project-local root needs no slug because
    /// the directory itself is the identity.
    ///
    /// - Parameter workingDirectory: The session working directory.
    /// - Returns: The slug, one safe path component.
    public static func projectSlug(forWorkingDirectory workingDirectory: URL) -> String {
        String(
            workingDirectory.standardizedFileURL.path.map { character in
                character.isLetter || character.isNumber ? character : Self.slugSeparator
            })
    }

    /// Resolves the recording root this location names (plan.md §4.1):
    /// `project` gives `<workingDirectory>/.<name>/transcripts/`, `home`
    /// gives `<userDirectory>/transcripts/<slug>/` under the shared user
    /// layer, and an absolute path is used as given.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session working directory (absolute).
    ///   - name: The validated dotfolder name; the project dotfolder is
    ///     `.<name>`.
    ///   - userDirectory: The user layer root, `~/.config/<name>/` in
    ///     production; tests inject a value so they never touch the real
    ///     home directory.
    /// - Returns: The directory `makeSession(recordingRoot:)` receives.
    public func recordingRoot(workingDirectory: URL, name: DotfolderName, userDirectory: URL)
        -> URL
    {
        switch self {
        case .project:
            return workingDirectory
                .appendingPathComponent(".\(name.rawValue)", isDirectory: true)
                .appendingPathComponent(Self.transcriptsDirectoryName, isDirectory: true)
        case .home:
            return userDirectory
                .appendingPathComponent(Self.transcriptsDirectoryName, isDirectory: true)
                .appendingPathComponent(
                    Self.projectSlug(forWorkingDirectory: workingDirectory), isDirectory: true)
        case .path(let url):
            return url
        }
    }
}

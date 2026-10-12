import Foundation

/// What stands at one path on disk: nothing, a directory, or something that
/// is not a directory.
///
/// Three callers ask this question: the existence check of `session/new`
/// and `session/resume`, ``ReadableDirectoryState``, and
/// ``WritableDirectoryCheck``. The probe is written one time here, so all
/// three treat a symbolic link and a file in place of a directory the same
/// way. The probe follows a symbolic link, so a link to a directory is a
/// directory.
enum PathKind: Equatable {
    /// Nothing stands at the path.
    case missing

    /// A directory stands at the path.
    case directory

    /// Something that is not a directory, for example a plain file, stands
    /// at the path.
    case notADirectory

    /// What stands at `url` on disk.
    ///
    /// - Parameter url: The path to test.
    /// - Returns: The kind of the path.
    static func of(_ url: URL) -> PathKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .notADirectory
    }
}

import Foundation

/// How one dotfolder layer directory stands on disk, for a `doctor`
/// component that must read it (cli-plan.md §5.12).
///
/// Two components ask the same question of two different stacks: the
/// configuration stack, and the skills stack. The answer is the same in
/// each case — the directory is not there, or it is there and cannot be
/// read, or it is there and can be read — so the rule and the command that
/// repairs it are written one time here, and each component states its own
/// name, message and further checks.
///
/// A layer that is not on disk is never a fault. Both stacks are built to
/// work with no file at all, so a missing layer is what a fresh install
/// looks like.
enum ReadableDirectoryState {
    /// Nothing stands at the path. The layer holds nothing, and the stack
    /// skips it.
    case missing

    /// Something stands at the path, and this process cannot read it.
    case unreadable

    /// Something stands at the path, and this process can read it.
    case readable

    /// The command that makes a layer directory readable. A `doctor` fix
    /// names it, so a person has the whole repair in one line.
    static let readFix = "chmod u+rx"

    /// How one directory stands on disk.
    ///
    /// - Parameter directory: The directory to test.
    /// - Returns: The state of that directory.
    static func of(_ directory: URL) -> ReadableDirectoryState {
        let path = directory.path
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else {
            return .missing
        }
        return manager.isReadableFile(atPath: path) ? .readable : .unreadable
    }
}

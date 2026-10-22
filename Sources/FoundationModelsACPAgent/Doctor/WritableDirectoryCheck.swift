import Foundation
import FoundationModelsExtras

/// The finding of one directory a `doctor` component needs writable
/// (cli-plan.md §5.12).
///
/// Three components ask the same question of different directories: the
/// transcripts recording root, the shell store, and the two roots of the
/// home (``HomeDoctor``). The answer is the same
/// in each case — the directory exists and can be written, or the nearest
/// directory above it can be written, so the code that owns it can create
/// it — so the rule is written one time here and each component states only
/// its own name, subject and fix.
///
/// ``MachineFigures`` reads the walk alone: a free-disk figure is measured
/// at the nearest directory above a model cache that is not on disk yet.
enum WritableDirectoryCheck {
    /// The finding of one directory.
    ///
    /// - Parameters:
    ///   - directory: The directory to check.
    ///   - name: What the finding is called in the report.
    ///   - subject: What stands at that path, as a noun phrase, for the
    ///     message of a path that is blocked by a file.
    ///   - category: The group the finding belongs to.
    ///   - fix: What to do about a directory that cannot be used. It takes
    ///     the directory that stands in the way, which is the target itself
    ///     or the nearest existing directory above it.
    /// - Returns: A pass, or the failure that says why the directory cannot
    ///   be used.
    static func check(
        of directory: URL, name: String, subject: String, category: String,
        fix: (URL) -> String
    ) -> HealthCheck {
        let target = directory.standardizedFileURL
        guard PathKind.of(target) != .notADirectory else {
            return .error(
                name: name,
                message: "\(target.path) is a file, so no \(subject) can stand there",
                fix: fix(target), category: category)
        }
        let existing = nearestExistingDirectory(of: target)
        guard FileManager.default.isWritableFile(atPath: existing.path) else {
            return .error(
                name: name,
                message: "\(existing.path) cannot be written, so \(target.path) cannot be used",
                fix: fix(existing), category: category)
        }
        guard existing != target else {
            return .ok(
                name: name, message: "\(target.path) exists and can be written",
                category: category)
        }
        return .ok(
            name: name,
            message: "\(target.path) is not on disk yet, and \(existing.path) can be written",
            category: category)
    }

    /// The nearest directory of `url`'s path that is on disk: `url` itself
    /// when it exists, else the closest one above it.
    ///
    /// - Parameter url: The path to walk up from.
    /// - Returns: The nearest existing directory. The walk ends at the file
    ///   system root, which always exists.
    static func nearestExistingDirectory(of url: URL) -> URL {
        var candidate = url
        while PathKind.of(candidate) == .missing {
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent != candidate else {
                return candidate
            }
            candidate = parent
        }
        return candidate
    }
}

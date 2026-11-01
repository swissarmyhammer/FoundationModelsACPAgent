import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The shape of a model reference, which this package states one time and
/// every reader takes from here: `owner/name`, and after it the revision a
/// reference pins, behind `@`.
///
/// Router's `ModelRef` is the owner of the format. It parses the same two
/// separators, but it keeps its `repo` part, its `revision` part and the
/// separator between them to itself, so no other package can read them. Thus
/// this package states the format here, beside the `profile:` section whose
/// slots hold the references, and no reader states it a second time. A change
/// to the format goes in this one file.
enum ModelReferenceFormat {
    /// The separator between the owner and the name of a repository id.
    static let ownerSeparator: Character = "/"

    /// The separator between the repository id and the revision a reference
    /// pins.
    static let revisionSeparator: Character = "@"

    /// The repository id and the revision of one reference.
    ///
    /// - Parameter reference: The reference to split.
    /// - Returns: The repository id, and the revision when the reference pins
    ///   one.
    static func parts(of reference: ModelRef) -> (repo: String, revision: String?) {
        let text = reference.stringValue
        guard let separator = text.firstIndex(of: revisionSeparator) else {
            return (text, nil)
        }
        return (String(text[..<separator]), String(text[text.index(after: separator)...]))
    }

    /// The starts of the repository part that make a reference a local
    /// folder and not a Hub repository id: an absolute path, a path from the
    /// home folder, and a path from the working directory. Router expands
    /// the last two when it resolves a profile.
    static let localPathPrefixes = ["/", "~", "./"]

    /// Whether a reference names a folder on the disk.
    ///
    /// - Parameter reference: The reference to test.
    /// - Returns: `true` when the repository part starts like a path.
    static func isLocalPath(_ reference: ModelRef) -> Bool {
        let repo = parts(of: reference).repo
        return localPathPrefixes.contains { repo.hasPrefix($0) }
    }

    /// The folder a local reference names, as an absolute URL. `~` is the
    /// home folder, and `./` is the working directory of the process, as
    /// Router reads them.
    ///
    /// - Parameter reference: A reference for which ``isLocalPath(_:)`` is
    ///   `true`.
    /// - Returns: The folder.
    static func localDirectory(of reference: ModelRef) -> URL {
        let repo = parts(of: reference).repo
        if repo.hasPrefix("~") {
            return URL(filePath: (repo as NSString).expandingTildeInPath)
        }
        return URL(filePath: repo, relativeTo: URL.currentDirectory()).standardizedFileURL
    }

    /// The format of the model in a local folder, by the rule of the loader.
    ///
    /// - Parameter directory: The folder.
    /// - Returns: The format, or `nil` when the folder is empty or cannot be
    ///   read.
    static func localFormat(of directory: URL) -> HubModelFormat? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
            !names.isEmpty
        else { return nil }
        return HubModelFormat.detect(paths: names)
    }
}

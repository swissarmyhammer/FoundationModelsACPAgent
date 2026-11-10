import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The shape of a model reference, as the readers of this package take it:
/// `owner/name[/path][@revision]`.
///
/// `ModelRef` of FoundationModelsExtras is the owner of the format and parses
/// it: the repository id is always the first two segments, each later
/// segment is a path inside the repository (a GGUF quantization folder or a
/// file), and the revision follows `@`. This file only gives its parts to
/// the readers of this package, so no reader parses the text a second time.
enum ModelReferenceFormat {
  /// The separator between the owner and the name of a repository id.
  static let ownerSeparator: Character = "/"

  /// The repository id and the revision of one reference. The path inside
  /// the repository is not part of the id.
  ///
  /// - Parameter reference: The reference to split.
  /// - Returns: The repository id, and the revision when the reference pins
  ///   one.
  static func parts(of reference: ModelRef) -> (repo: String, revision: String?) {
    (reference.repo, reference.revision)
  }

  /// Whether a reference names a folder or a file on the disk and not a Hub
  /// repository: its text starts with `/`, `~` or `.`, as the loader reads
  /// it.
  ///
  /// - Parameter reference: The reference to test.
  /// - Returns: `true` when the reference is local.
  static func isLocalPath(_ reference: ModelRef) -> Bool {
    reference.isLocal
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

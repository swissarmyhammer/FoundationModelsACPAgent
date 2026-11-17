import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The profiles that ship in the resources of the library:
/// `Resources/profiles/large.yaml` and `Resources/profiles/small.yaml`.
///
/// They are the lowest layer of the profiles, under the user layer and the
/// project layer (``ProfileStore``), and they are read-only. `large` is the
/// default profile, and each key that a profile file leaves out takes its
/// value from `large` (``ProfileFile``).
///
/// The files are part of the library, and the unit tests pin their contents,
/// thus a file that does not decode is a fault of the build and stops the
/// process.
public enum BundledProfiles {
  /// The name of the default profile.
  public static let defaultName = "large"

  /// The names of the bundled profiles, in the order that a list shows them.
  static let names = [defaultName, "small"]

  /// The keys of the default profile file: the base of the merge of each
  /// profile file.
  static let baseKeys: [String: YAMLValue] = {
    guard case .dictionary(let keys) = tree(of: defaultName) else {
      preconditionFailure("the bundled profile \(defaultName) is not a mapping")
    }
    return keys
  }()

  /// The bundled profiles, in the order of ``names``.
  public static let all: [ProfileDefinition] = names.map { name in
    do {
      return try ProfileFile.definition(of: tree(of: name), name: name, path: path(of: name))
    } catch {
      preconditionFailure("the bundled profile \(name) does not decode: \(error)")
    }
  }

  /// The default profile, `large`.
  public static var defaultProfile: ProfileDefinition {
    guard let profile = named(defaultName) else {
      preconditionFailure("the bundled profiles have no profile named \(defaultName)")
    }
    return profile
  }

  /// The bundled profile that has a name.
  ///
  /// - Parameter name: The name.
  /// - Returns: The profile, or `nil` when no bundled profile has the name.
  public static func named(_ name: String) -> ProfileDefinition? {
    all.first { $0.name == name }
  }

  /// The location of a bundled profile file in the resource bundle.
  ///
  /// - Parameter name: The name of the profile.
  /// - Returns: The file URL, or `nil` when the bundle has no such file.
  static func url(of name: String) -> URL? {
    Bundle.module.url(
      forResource: name, withExtension: ProfileFile.fileExtension,
      subdirectory: ProfileFile.folderName)
  }

  /// The path of a bundled profile file, for the errors.
  ///
  /// - Parameter name: The name of the profile.
  /// - Returns: The path, or the bare file name when the bundle has no file.
  static func path(of name: String) -> String {
    url(of: name)?.path ?? "\(name).\(ProfileFile.fileExtension)"
  }

  /// The parsed tree of a bundled profile file.
  ///
  /// - Parameter name: The name of the profile.
  /// - Returns: The tree.
  private static func tree(of name: String) -> YAMLValue {
    guard let url = url(of: name), let text = try? String(contentsOf: url, encoding: .utf8),
      let tree = try? YAMLValue.parse(text)
    else {
      preconditionFailure("the bundled profile \(name) cannot be read")
    }
    return tree
  }
}

import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import GraphQL

/// A profile file that does not decode. Each case names the file.
public enum ProfileFileError: Error, Equatable, Sendable, CustomStringConvertible {
  /// The file cannot be read as UTF-8 text. `reason` is the reason of the
  /// file system.
  case unreadable(path: String, reason: String)

  /// The text of the file is not YAML. `message` is the message of the
  /// parser.
  case malformed(path: String, message: String)

  /// The text of the file is not a mapping of keys.
  case notAMapping(path: String)

  /// The file has a key that a profile does not have.
  case unknownKey(path: String, key: String)

  /// The file has a `name` key that is not the name of the file.
  case nameMismatch(path: String, name: String)

  /// A value of the file does not decode, for example a slot that is not a
  /// list of models. `message` is the message of the decoder.
  case invalidValue(path: String, message: String)

  /// A human-readable reason that names the file.
  public var description: String {
    switch self {
    case .unreadable(let path, let reason):
      "the profile file \(path) cannot be read: \(reason)"
    case .malformed(let path, let message):
      "the profile file \(path) is not YAML: \(message)"
    case .notAMapping(let path):
      "the profile file \(path) must be a mapping of keys"
    case .unknownKey(let path, let key):
      "the profile file \(path) has the unknown key \"\(key)\"; the keys are: "
        + ProfileFile.knownKeys.sorted().joined(separator: ", ")
    case .nameMismatch(let path, let name):
      "the profile file \(path) has the name \"\(name)\", and the name of a profile is the name of its file"
    case .invalidValue(let path, let message):
      "the profile file \(path) has a value that is not valid: \(message)"
    }
  }
}

/// One profile file, `<name>.yaml` in a `profiles` folder: Router's
/// `ProfileDefinition` in YAML, with the name of the file as its name.
///
/// Each key is optional. A key that the file leaves out takes the default of
/// Router's `ProfileDefinition`, and never a key of an other profile, of the
/// selected profile or of an other layer. A key that a profile does not have,
/// and a value that does not decode, are errors that name the file.
enum ProfileFile {
  /// The extension of a profile file.
  static let fileExtension = "yaml"

  /// The folder of the profile files in a dotfolder layer, and in the
  /// resources of the library.
  static let folderName = "profiles"

  /// The key of the name, which only the name of the file can have.
  static let nameKey = "name"

  /// The keys of a profile file: the keys of Router's `ProfileDefinition`.
  /// `kvBits` is a key of the file before Router decodes it. `cluster: off`
  /// keeps the models of the profile on this Mac, whatever the `cluster:`
  /// section of `config.yaml` says.
  static let knownKeys: Set<String> = [
    nameKey, "description", "standard", "flash", "embedding", "decision", "context",
    "decisionContext", "kvBits", clusterKey,
  ]

  /// The key that keeps the models of a profile on this Mac: its one value
  /// is `off` (Router's `ProfileClusterSetting`).
  static let clusterKey = "cluster"

  /// Decodes the text of a profile file.
  ///
  /// - Parameters:
  ///   - text: The text of the file.
  ///   - name: The name of the profile: the name of the file without its
  ///     extension.
  ///   - path: The path of the file, for the errors.
  /// - Returns: The profile.
  /// - Throws: ``ProfileFileError``.
  static func definition(ofText text: String, name: String, path: String) throws(ProfileFileError)
    -> ProfileDefinition
  {
    let tree: YAMLValue
    do {
      tree = try YAMLValue.parse(text)
    } catch {
      throw .malformed(path: path, message: String(describing: error))
    }
    return try definition(of: tree, name: name, path: path)
  }

  /// Decodes the tree of a profile file as Router's `ProfileDefinition`,
  /// with the name of the file as its name. Router gives the default of
  /// each key that the file leaves out.
  ///
  /// - Parameters:
  ///   - tree: The tree of the file. `.null` is an empty file.
  ///   - name: The name of the profile.
  ///   - path: The path of the file, for the errors.
  /// - Returns: The profile.
  /// - Throws: ``ProfileFileError``.
  static func definition(of tree: YAMLValue, name: String, path: String) throws(ProfileFileError)
    -> ProfileDefinition
  {
    var keys = try checkedKeys(of: tree, name: name, path: path)
    keys[nameKey] = .string(name)
    // YAML reads a bare `off` as the Boolean false; the file means the word.
    if keys[clusterKey] == .bool(false) {
      keys[clusterKey] = .string(ProfileClusterSetting.off.rawValue)
    }
    do {
      return try YAMLValue.dictionary(keys).decoded(as: ProfileDefinition.self)
    } catch {
      throw .invalidValue(path: path, message: String(describing: error))
    }
  }

  /// The keys of the tree of a profile file, after the checks of the keys.
  ///
  /// - Parameters:
  ///   - tree: The tree of the file.
  ///   - name: The name of the profile.
  ///   - path: The path of the file, for the errors.
  /// - Returns: The keys and their values; none for an empty file.
  /// - Throws: ``ProfileFileError/notAMapping(path:)``,
  ///   ``ProfileFileError/unknownKey(path:key:)`` for the first unknown key
  ///   in key order, or ``ProfileFileError/nameMismatch(path:name:)``.
  private static func checkedKeys(of tree: YAMLValue, name: String, path: String)
    throws(ProfileFileError) -> [String: YAMLValue]
  {
    switch tree {
    case .null:
      return [:]
    case .dictionary(let keys):
      if let unknown = keys.keys.sorted().first(where: { !knownKeys.contains($0) }) {
        throw .unknownKey(path: path, key: unknown)
      }
      if let fileName = keys[nameKey], fileName != .string(name) {
        let shown = if case .string(let text) = fileName { text } else { "\(fileName)" }
        throw .nameMismatch(path: path, name: shown)
      }
      return keys
    case .string, .int, .double, .bool, .array:
      throw .notAMapping(path: path)
    }
  }

  /// The text of the file of a profile: each key of the profile but its
  /// name, in key order.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The YAML text, which decodes back to the profile under the
  ///   name of its file.
  /// - Throws: The encoding error.
  static func text(of profile: ProfileDefinition) throws -> String {
    guard case .dictionary(var keys) = try tree(of: profile) else {
      throw ConfigurationYAML.EmitError.notAMapping
    }
    keys[nameKey] = nil
    return try ConfigurationYAML.levelText(of: .dictionary(keys))
  }

  /// The tree of a profile, from its `Codable` encoding.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The tree.
  /// - Throws: The encoding error.
  static func tree(of profile: ProfileDefinition) throws -> YAMLValue {
    YAMLValue(graphQLMap: try JSONDecoder().decode(Map.self, from: JSONEncoder().encode(profile)))
  }
}

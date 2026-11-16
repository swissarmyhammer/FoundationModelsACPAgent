import Foundation
import FoundationModelsACP

/// The shape of the keys of the `statusline` setting: the same data as
/// `StatusLineDefinition.settingsSchema` of AgentViewKit (AVK-10, D194 (g)).
///
/// AgentViewKit depends on this package, thus this package cannot read the
/// AgentViewKit schema. It keeps a copy, and a test of AgentViewKit checks
/// that ``StatusLineConfiguration/settingsKeys`` is the same as its own
/// `StatusLineDefinition.settingsKeys`.
public indirect enum StatusLineSettingsSchema: Equatable, Sendable {
  /// A value with no keys below it.
  case value

  /// A mapping with these keys.
  case object([String: StatusLineSettingsSchema])

  /// A list whose elements have this shape.
  case list(StatusLineSettingsSchema)
}

/// The top-level `statusline` section: the status line of the chat header
/// of AgentViewKit (ACPA-22, D194).
///
/// The agent does not use the value. It keeps the raw value and gives it to
/// the clients through the `settings` endpoint (D193). AgentViewKit
/// resolves it (`StatusLineSetting.resolve`).
///
/// The decode checks the value against ``settingsSchema``, thus the settings
/// store refuses a wrong change before it writes a file:
///
/// - Each key of a mapping is a key of the schema; an unknown key is a
///   problem that names its key path.
/// - A mapping of the schema is a mapping, and a list is a list.
/// - `preset` and `format` are strings.
/// - A key with the value `null` is not set. A top key with `null` is not
///   kept, thus a document that names each key reads back to the same
///   value.
///
/// ```yaml
/// statusline:
///   preset: default
///   directory:
///     truncation_length: 3
/// ```
public struct StatusLineConfiguration: Codable, Equatable, Sendable {
  /// The key of the preset.
  public static let presetKey = "preset"

  /// The key of the format.
  static let formatKey = "format"

  /// The preset of the builtin configuration.
  public static let defaultPreset = "default"

  /// The builtin presets of AgentViewKit.
  static let presets = ["default", "minimal", "full"]

  /// The module names, in the order of the status line.
  static let moduleNames = [
    "directory", "git_branch", "git_status", "git_state", "languages", "session", "agent", "model",
    "context", "time",
  ]

  /// The keys of every module.
  private static let commonModuleKeys = ["format", "style", "disabled"]

  /// A module with the common keys and these keys.
  ///
  /// - Parameter keys: The other keys of the module.
  /// - Returns: The schema of the module.
  private static func module(_ keys: [String: StatusLineSettingsSchema] = [:]) -> StatusLineSettingsSchema {
    .object(
      Dictionary(uniqueKeysWithValues: commonModuleKeys.map { ($0, StatusLineSettingsSchema.value) })
        .merging(keys) { _, new in new })
  }

  /// Each key as a plain value.
  ///
  /// - Parameter names: The keys.
  /// - Returns: The keys with the shape ``StatusLineSettingsSchema/value``.
  private static func values(_ names: String...) -> [String: StatusLineSettingsSchema] {
    Dictionary(uniqueKeysWithValues: names.map { ($0, StatusLineSettingsSchema.value) })
  }

  /// The shape of the keys of the section: a copy of
  /// `StatusLineDefinition.settingsSchema` of AgentViewKit.
  public static let settingsSchema: StatusLineSettingsSchema = .object(
    values(presetKey, formatKey).merging([
      "directory": module(
        values(
          "truncation_length", "truncate_to_repo", "truncation_symbol", "home_symbol",
          "fish_style_pwd_dir_length", "repo_root_style"
        ).merging(["substitutions": .list(.object(values("from", "to")))]) { _, new in new }),
      "git_branch": module(
        values("symbol", "truncation_length", "truncation_symbol", "only_attached")
          .merging(["ignore_branches": .list(.value)]) { _, new in new }),
      "git_status": module(
        values(
          "conflicted", "ahead", "behind", "diverged", "up_to_date", "untracked", "stashed",
          "modified", "staged", "renamed", "deleted", "ignore_submodules")),
      "git_state": module(
        values("rebase", "merge", "revert", "cherry_pick", "bisect", "am", "am_or_rebase")),
      "languages": module(
        values("maximum", "minimum_files").merging([
          "languages": .list(
            .object(
              values("name", "symbol", "disabled").merging([
                "detect_extensions": .list(.value), "detect_files": .list(.value),
                "detect_folders": .list(.value),
              ]) { _, new in new }))
        ]) { _, new in new }),
      "session": module(values("truncation_length", "shows_path")),
      "agent": module(),
      "model": module(values("symbol")),
      "context": module(
        values("symbol", "bar_width").merging([
          "thresholds": .list(.object(values("below", "style")))
        ]) { _, new in new }),
      "time": module(values("time_format")),
    ]) { _, new in new })

  /// Each key path of ``settingsSchema``, sorted by its dotted form: the
  /// same list as `StatusLineDefinition.settingsKeys` of AgentViewKit. A
  /// step `*` is each element of a list.
  public static let settingsKeys: [[String]] = keyPaths(of: settingsSchema, prefix: []).sorted {
    $0.joined(separator: ".") < $1.joined(separator: ".")
  }

  /// The key paths below one shape.
  ///
  /// - Parameters:
  ///   - schema: The shape.
  ///   - prefix: The key path of the shape.
  /// - Returns: The key paths.
  private static func keyPaths(of schema: StatusLineSettingsSchema, prefix: [String]) -> [[String]] {
    switch schema {
    case .value:
      return []
    case .list(let element):
      return keyPaths(of: element, prefix: prefix + ["*"])
    case .object(let keys):
      return keys.flatMap { key, child in
        [prefix + [key]] + keyPaths(of: child, prefix: prefix + [key])
      }
    }
  }

  /// The top keys of the section.
  static let topKeys = Set(settingsKeys.filter { $0.count == 1 }.map { $0[0] })

  /// The text of the `settings` tool about this section.
  static let help =
    "The `statusline` section sets the status line of the chat header: `preset` is "
    + presets.joined(separator: ", ")
    + "; `format` is the format string; and a module key changes one module of the preset: "
    + moduleNames.joined(separator: ", ") + "."

  /// The raw value of the section.
  public var value: JSONValue

  /// Makes a section with this raw value. The value is not checked.
  ///
  /// - Parameter value: The raw value.
  public init(value: JSONValue = .object([presetKey: .string(defaultPreset)])) {
    self.value = value
  }

  /// Decodes the raw value, and checks it against ``settingsSchema``. A top
  /// key whose value is `null` is not kept.
  ///
  /// - Parameter decoder: The decoder of the section.
  /// - Throws: `DecodingError.dataCorrupted` for the first problem.
  public init(from decoder: any Decoder) throws {
    let value = try JSONValue(from: decoder)
    if let problem = Self.problem(in: value) {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: problem))
    }
    if case .object(let fields) = value {
      self.value = .object(fields.filter { $0.value != .null })
    } else {
      self.value = value
    }
  }

  /// Encodes the raw value.
  ///
  /// - Parameter encoder: The encoder.
  /// - Throws: The error of the encoder.
  public func encode(to encoder: any Encoder) throws {
    try value.encode(to: encoder)
  }

  /// The first problem of a value, or `nil` when it passes.
  ///
  /// - Parameter value: The raw value.
  /// - Returns: The problem text, which names the key path.
  static func problem(in value: JSONValue) -> String? {
    for key in [presetKey, formatKey] {
      if case .object(let fields) = value, let field = fields[key], field != .null {
        guard case .string = field else {
          return "statusline.\(key) must be a string"
        }
      }
    }
    return problem(in: value, schema: settingsSchema, path: ["statusline"])
  }

  /// The first problem of a value against one shape.
  ///
  /// - Parameters:
  ///   - value: The value.
  ///   - schema: The shape.
  ///   - path: The key path of the value.
  /// - Returns: The problem text, or `nil`.
  private static func problem(in value: JSONValue, schema: StatusLineSettingsSchema, path: [String])
    -> String?
  {
    let name = path.joined(separator: ".")
    switch (schema, value) {
    case (_, .null), (.value, _):
      return nil
    case (.object(let keys), .object(let fields)):
      for key in fields.keys.sorted() {
        guard let child = keys[key] else {
          return "unknown key \"\(name).\(key)\"; the keys are: "
            + keys.keys.sorted().joined(separator: ", ")
        }
        if let problem = problem(in: fields[key] ?? .null, schema: child, path: path + [key]) {
          return problem
        }
      }
      return nil
    case (.object, _):
      return "\(name) must be a mapping"
    case (.list(let element), .array(let items)):
      for (index, item) in items.enumerated() {
        if let problem = problem(in: item, schema: element, path: path + ["\(index)"]) {
          return problem
        }
      }
      return nil
    case (.list, _):
      return "\(name) must be a list"
    }
  }
}

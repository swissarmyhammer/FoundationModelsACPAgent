import Foundation
import FoundationModelsACP

/// The top-level `statusline` section: the status line of the chat header
/// of AgentViewKit (ACPA-22, D194).
///
/// The agent does not use the value. It keeps the raw value and gives it to
/// the clients through the `settings` endpoint (D193). AgentViewKit
/// resolves it (`StatusLineSetting.resolve`).
///
/// The decode checks the keys at two levels, thus the settings store
/// refuses a wrong change before it writes a file:
///
/// - The top keys are `preset`, `format` and the module names. `preset`
///   and `format` are strings.
/// - The value of a module is a mapping, and its keys are the keys of that
///   module.
/// - A top key with the value `null` is not set.
///
/// ```yaml
/// statusline:
///   preset: default
///   directory:
///     truncation_length: 3
/// ```
///
/// The module keys are a fixed list until AgentViewKit gives
/// `StatusLineDefinition.settingsKeys` (AVK-10); then this list uses it.
public struct StatusLineConfiguration: Codable, Equatable, Sendable {
  /// The key of the preset.
  public static let presetKey = "preset"

  /// The key of the format.
  static let formatKey = "format"

  /// The preset of the builtin configuration.
  public static let defaultPreset = "default"

  /// The builtin presets of AgentViewKit.
  static let presets = ["default", "minimal", "full"]

  /// The keys that each module has.
  static let commonModuleKeys = ["disabled", "format", "style", "symbol"]

  /// The keys of each module, by module name, after ``commonModuleKeys``.
  static let moduleKeys: [String: [String]] = [
    "directory": ["truncation_length", "truncate_to_repo", "fish_style_pwd_dir_length", "home_symbol"],
    "git_branch": ["truncation_length", "truncation_symbol", "only_attached"],
    "git_status": [
      "ahead", "behind", "diverged", "conflicted", "untracked", "stashed", "modified", "staged",
      "renamed", "deleted",
    ],
    "git_state": ["rebase", "merge", "cherry_pick", "revert", "bisect", "am"],
    "languages": ["max_count"],
    "session": ["show_crumbs"],
    "agent": [],
    "model": [],
    "context": ["warning_threshold"],
    "time": ["time_format", "utc_time_offset"],
  ]

  /// The module names, in the order of the status line.
  static let moduleNames = [
    "directory", "git_branch", "git_status", "git_state", "languages", "session", "agent", "model",
    "context", "time",
  ]

  /// The top keys of the section.
  static let topKeys = Set([presetKey, formatKey] + moduleNames)

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

  /// Decodes the raw value, and checks its keys at two levels. A top key
  /// whose value is `null` is not kept, thus a document that names each key
  /// reads back to the same value.
  ///
  /// - Parameter decoder: The decoder of the section.
  /// - Throws: `DecodingError.dataCorrupted` for an unknown key, a `preset`
  ///   or `format` that is not a string, or a module that is not a mapping.
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
  /// - Returns: The problem text.
  static func problem(in value: JSONValue) -> String? {
    guard case .object(let fields) = value else {
      return value == .null ? nil : "statusline must be a mapping"
    }
    for key in fields.keys.sorted() {
      guard topKeys.contains(key) else {
        return "unknown statusline key \"\(key)\"; the keys are: "
          + ([presetKey, formatKey] + moduleNames).joined(separator: ", ")
      }
      if let problem = problem(ofKey: key, value: fields[key] ?? .null) {
        return problem
      }
    }
    return nil
  }

  /// The problem of one top key, or `nil`.
  ///
  /// - Parameters:
  ///   - key: The top key.
  ///   - value: Its value.
  /// - Returns: The problem text.
  private static func problem(ofKey key: String, value: JSONValue) -> String? {
    // A null key is not set: `config init` writes each key of the schema.
    guard value != .null else {
      return nil
    }
    if key == presetKey || key == formatKey {
      guard case .string = value else {
        return "statusline.\(key) must be a string"
      }
      return nil
    }
    guard case .object(let fields) = value else {
      return "statusline.\(key) must be a mapping of module keys"
    }
    let known = commonModuleKeys + (moduleKeys[key] ?? [])
    guard let unknown = fields.keys.sorted().first(where: { !known.contains($0) }) else {
      return nil
    }
    return "unknown statusline.\(key) key \"\(unknown)\"; the keys are: "
      + known.joined(separator: ", ")
  }
}

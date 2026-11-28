import Foundation

// MARK: - profiles

/// The `profiles:` section: the settings of each model profile, by the name
/// of the profile (D218).
///
/// Each key of the section is the name of a profile, for example `large`,
/// and its value is a ``ProfileSettings``. The section does not select a
/// profile: the `profile` key does that. A name that no layer has as a
/// profile file is not an error, because a profile file can come later. The
/// user level and the session level of a folder can set each key, as each
/// other key (D100 (f)), and the session level wins.
public struct ProfilesConfiguration: Codable, Equatable, Sendable {
  /// The key of the section in the root of `config.yaml`.
  public static let sectionKey = AgentConfiguration.CodingKeys.profiles.stringValue

  /// The help of the section, for the `settings` tool.
  public static let help =
    "The key path [\"profiles\", <profile name>, \"effort\"] takes the default reasoning effort of "
    + "the new sessions on that profile: a level of its standard model, such as \"low\" or \"high\". "
    + "The models tool gives the levels of each profile. A value that is not a level of the model "
    + "gives a warning, and the session takes the default level of the model."

  /// The settings of each profile, by the name of the profile.
  public var entries: [String: ProfileSettings]

  /// Makes the section.
  ///
  /// - Parameter entries: The settings of each profile, by the name of the
  ///   profile. The default is none.
  public init(entries: [String: ProfileSettings] = [:]) {
    self.entries = entries
  }

  /// Decodes the mapping from the name of each profile to its settings.
  ///
  /// - Parameter decoder: The decoder of the section.
  /// - Throws: `DecodingError` when the section is not a mapping, or when a
  ///   value of a profile does not decode.
  public init(from decoder: any Decoder) throws {
    entries = try decoder.singleValueContainer().decode([String: ProfileSettings].self)
  }

  /// Encodes the mapping from the name of each profile to its settings.
  ///
  /// - Parameter encoder: The encoder of the section.
  /// - Throws: The error of the encoder.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(entries)
  }

  /// The default reasoning effort of the new sessions on a profile: the
  /// `effort` key of the profile.
  ///
  /// - Parameter profileName: The name of the profile.
  /// - Returns: The value, or `nil` when no layer sets it.
  public func effort(of profileName: String) -> String? {
    entries[profileName]?.effort
  }
}

/// The settings of one profile under `profiles:` (D218).
public struct ProfileSettings: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The default reasoning effort of the new sessions on the profile: a
  /// name of the levels of the standard model of the profile, or `nil` for
  /// the default level of the model. The agent gives it to each new root
  /// session on the profile (`session/new`). A name that is not a level of
  /// the model gives a warning, and the session takes the default level of
  /// the model.
  public var effort: String?

  /// The YAML spelling of each key.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case effort
  }

  /// Makes the settings of one profile.
  ///
  /// - Parameter effort: The default reasoning effort, or `nil` (the
  ///   default) for the default level of the model.
  public init(effort: String? = nil) {
    self.effort = effort
  }
}

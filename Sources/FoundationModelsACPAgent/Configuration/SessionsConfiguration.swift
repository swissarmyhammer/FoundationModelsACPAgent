import Foundation
import FoundationModelsExtras

// MARK: - sessions

/// The `sessions:` section: the settings of the sessions of the agent
/// (D206).
///
/// The `recap` key turns the session recap on and off. The user level and
/// the session level of a folder can set it, and the session level wins.
/// ``SettingsStore/isSessionRecapOn(for:)`` gives the merged value for a
/// folder.
public struct SessionsConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The default of ``recap``: the recap is on.
  public static let defaultRecap = true

  /// The description of the `sessions.recap` key, for the `settings` tool.
  public static let recapDescription =
    "Write a one-sentence recap of each session with the flash model (D206)."

  /// When true, the agent writes a one-sentence recap of each session with
  /// the `flash` model of the profile.
  public var recap = SessionsConfiguration.defaultRecap

  /// The YAML spelling of each key.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case recap
  }

  /// The default: the recap is on.
  public init() {}

  /// Decodes each present key and keeps the default for each absent one.
  ///
  /// - Parameter decoder: The decoder of the section.
  /// - Throws: `DecodingError` when `recap` is not a Boolean.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    recap = try container.decodeIfPresent(Bool.self, forKey: .recap) ?? recap
  }
}

extension SettingsStore {
  /// Tells if the agent writes a recap of a session of a folder: the merged
  /// value of `sessions.recap` for that folder.
  ///
  /// Each call reads the levels that the store holds now. A change through
  /// the store, and an outside write of a level file that the store
  /// watches, thus applies at the next call, with no restart.
  ///
  /// - Parameter workingDirectory: The working directory of the session.
  /// - Returns: The merged value: the session level of the folder, else the
  ///   user level, else the builtin default (true).
  /// - Throws: What ``value(at:cwd:)`` throws for a level file; a
  ///   `DecodingError` when the merged value is not a Boolean.
  public func isSessionRecapOn(for workingDirectory: URL) throws -> Bool {
    guard
      let setting = try value(
        at: [AgentConfiguration.CodingKeys.sessions.stringValue], cwd: workingDirectory)
    else {
      return SessionsConfiguration.defaultRecap
    }
    return try setting.value.decoded(as: SessionsConfiguration.self).recap
  }
}

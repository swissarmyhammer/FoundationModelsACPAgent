import Foundation

// MARK: - spotlight

/// The `spotlight:` section: one switch for each kind of Core Spotlight item of the app (D214).
///
/// The app writes and removes the items. The agent applies no rule to these keys: the app reads
/// them. The user level and the session level of a folder can set each key, as each other key
/// (D100 (f)). The app uses the user level of each key, and the session level of
/// ``enabled`` only: `false` in a folder keeps that folder out of Spotlight.
public struct SpotlightConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The key of the section in the root of `config.yaml`.
  public static let sectionKey = AgentConfiguration.CodingKeys.spotlight.stringValue

  /// The help of the section, for the `settings` tool.
  public static let help =
    "The key paths [\"spotlight\", <key>] take true or false and turn the Spotlight items of the "
    + "app on or off: enabled (all items; false in a folder keeps that folder out), sessions, "
    + "archivedSessions, automatedSessions, tasks, library, externalSessions, settings, commands."

  /// When true, the app writes Spotlight items. When false at the user level, the app writes
  /// none. When false at the session level of a folder, the app writes no item of that folder.
  public var enabled = true

  /// When true, the app writes an item for each session.
  public var sessions = true

  /// When true, the app writes an item for each archived session too.
  public var archivedSessions = false

  /// When true, the app writes an item for each automated session too.
  public var automatedSessions = false

  /// When true, the app writes an item for each board and each task.
  public var tasks = true

  /// When true, the app writes an item for each agent, skill, rule and MCP server.
  public var library = true

  /// When true, the app writes an item for each typed session of another agent.
  public var externalSessions = true

  /// When true, the app writes an item for each setting.
  public var settings = true

  /// When true, the app writes an item for each command.
  public var commands = true

  /// The YAML spelling of each key.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case enabled, sessions, archivedSessions, automatedSessions, tasks, library
    case externalSessions, settings, commands
  }

  /// The default of each key.
  public init() {}

  /// Decodes each present key and keeps the default for each absent one.
  ///
  /// - Parameter decoder: The decoder of the section.
  /// - Throws: `DecodingError` when a key is not a Boolean.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func value(_ key: CodingKeys, _ fallback: Bool) throws -> Bool {
      try container.decodeIfPresent(Bool.self, forKey: key) ?? fallback
    }
    enabled = try value(.enabled, enabled)
    sessions = try value(.sessions, sessions)
    archivedSessions = try value(.archivedSessions, archivedSessions)
    automatedSessions = try value(.automatedSessions, automatedSessions)
    tasks = try value(.tasks, tasks)
    library = try value(.library, library)
    externalSessions = try value(.externalSessions, externalSessions)
    settings = try value(.settings, settings)
    commands = try value(.commands, commands)
  }
}

import Foundation
import FoundationModelsExtras

// MARK: - sessions

/// The `sessions:` section: the settings of the sessions of the agent
/// (D206).
///
/// The `recap` key turns the session recap on and off. The user level and
/// the session level of a folder can set it, and the session level wins.
/// ``SettingsStore/isSessionRecapOn(for:)`` gives the merged value for a
/// folder. ``SettingsStore/isSessionRecapOnNow(for:)`` gives it with no hop
/// to the store, as the recap policy of the Router session directory.
public struct SessionsConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The default of ``recap``: the recap is on.
  public static let defaultRecap = true

  /// The description of the `sessions.recap` key, for the `settings` tool.
  public static let recapDescription =
    "Write a one-sentence recap of each session with the flash model (D206)."

  /// When true, the agent writes a one-sentence recap of each session with
  /// the `flash` model of the profile.
  public var recap = SessionsConfiguration.defaultRecap

  /// The key of the section in the root of `config.yaml`.
  static let sectionKey = AgentConfiguration.CodingKeys.sessions.stringValue

  /// The `recap` value of a merged `sessions` section.
  ///
  /// - Parameter section: The merged value of the `sessions` key, or `nil`
  ///   when no layer sets it.
  /// - Returns: The decoded `recap`, or ``defaultRecap`` when the section
  ///   or its `recap` key is not there.
  /// - Throws: `DecodingError` when the section is not a mapping, or when
  ///   `recap` is not a Boolean.
  static func recap(in section: YAMLValue?) throws -> Bool {
    guard let section else {
      return defaultRecap
    }
    return try section.decoded(as: SessionsConfiguration.self).recap
  }

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
    try SessionsConfiguration.recap(
      in: value(at: [SessionsConfiguration.sectionKey], cwd: workingDirectory)?.value)
  }

  /// Tells, with no hop to the store, if the agent writes a recap of a
  /// session of a folder: the merged value of `sessions.recap` for that
  /// folder. It is the recap policy that the agent gives to the Router
  /// session directory (`RouterSessionDirectory.useRecapPolicy(_:)`), which
  /// asks it synchronously at the end of each turn and before each recap
  /// call.
  ///
  /// The call does not wait and does not block the store. It reads the
  /// copy of the levels that the store keeps up to date
  /// (``mergedRootNow(for:)``), thus a `set` or a `clear` through the
  /// store, and an outside write of a level file after the watcher of the
  /// store reads it again, apply at the next call, with no restart. A level
  /// that the store does not hold yet is read from its file.
  ///
  /// When the read or the decode fails, the call logs a warning and gives
  /// the default, ``SessionsConfiguration/defaultRecap`` (the recap is on).
  ///
  /// - Parameter workingDirectory: The working directory of the session.
  /// - Returns: The merged value: the session level of the folder, else the
  ///   user level, else the defaults layer, else the default (true).
  public nonisolated func isSessionRecapOnNow(for workingDirectory: URL) -> Bool {
    do {
      return try SessionsConfiguration.recap(
        in: mergedRootNow(for: workingDirectory).value(at: [SessionsConfiguration.sectionKey]))
    } catch {
      ACPAgentTelemetry.logger(.configuration).warning(
        "The sessions.recap setting could not be read. The recap stays on.",
        metadata: ACPAgentTelemetry.errorMetadata(error))
      return SessionsConfiguration.defaultRecap
    }
  }
}

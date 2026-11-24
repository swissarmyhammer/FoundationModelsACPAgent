import Foundation

/// A change of the `spotlight.enabled` setting (D214, part 6).
public enum SpotlightSettingChange: Sendable, Equatable {
  /// The user level changed: the value of each folder with no session-level value can change.
  case user

  /// The session level of this folder changed.
  case folder(URL)
}

/// The folder setting of the content catalog (D214, part 6): the merged value of
/// `spotlight.enabled` for a known folder (the session level of the folder, else the user level,
/// else the builtin default), and a stream of its changes. The host keeps a folder out of
/// Spotlight when the value is `false`.
public struct SpotlightFolderSettings: Sendable {
  /// The key path of `spotlight.enabled`.
  static let enabledKeyPath = [
    SpotlightConfiguration.sectionKey, SpotlightConfiguration.CodingKeys.enabled.stringValue,
  ]

  /// The settings store of the agent.
  private let store: SettingsStore

  /// Makes the part.
  ///
  /// - Parameter store: The settings store of the agent.
  init(store: SettingsStore) {
    self.store = store
  }

  /// The merged value of `spotlight.enabled` for a folder. The read also starts the watch of
  /// the session level of the folder, so an outside edit of its `config.yaml` gives a change.
  ///
  /// - Parameter folder: The working folder.
  /// - Returns: The value: the session level of the folder, else the user level, else `true`.
  /// - Throws: The error of a level file, or a `DecodingError` when the value is not a Boolean.
  public func isEnabled(in folder: URL) async throws -> Bool {
    try await store.startWatching(cwd: folder)
    guard let value = try await store.value(at: Self.enabledKeyPath, cwd: folder)?.value else {
      return SpotlightConfiguration().enabled
    }
    return try value.decoded(as: Bool.self)
  }

  /// Makes a new stream of the changes of `spotlight.enabled`. Each call gives a new stream of
  /// its own. A change of a level gives an element when it can change the value: a change of the
  /// key, of the `spotlight` section or of the root, or an outside edit of the file of the level.
  /// A change of another key gives none. The host then reads ``isEnabled(in:)`` again.
  ///
  /// - Returns: The stream of the changes after this call. It ends when the subscriber stops it.
  public func changes() -> AsyncStream<SpotlightSettingChange> {
    let source = store.changes()
    let (stream, continuation) = AsyncStream.makeStream(of: SpotlightSettingChange.self)
    let task = Task {
      for await change in source where Self.reaches(change.keyPath) {
        switch change.level {
        case .user:
          continuation.yield(.user)
        case .session(let folder):
          continuation.yield(.folder(folder.standardizedFileURL))
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  /// Whether a change at `keyPath` can change `spotlight.enabled`.
  ///
  /// - Parameter keyPath: The key path of the change, or `nil` for an outside edit.
  /// - Returns: True for an outside edit, and for a key path on the way to the key or inside it.
  private static func reaches(_ keyPath: [String]?) -> Bool {
    guard let keyPath else { return true }
    return enabledKeyPath.starts(with: keyPath) || keyPath.starts(with: enabledKeyPath)
  }
}

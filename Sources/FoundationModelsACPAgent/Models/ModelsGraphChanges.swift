import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

// The change feed of the `models` endpoint (EXTRAS-9 rule 9): one change log
// of each endpoint, fed by the changes of `profile.preset` in the settings
// store, and by a watch of the disk state of the models of the builtin
// profiles.

/// One change of the `models` endpoint.
struct ModelsGraphChangeEvent: Sendable {
  /// The slots that changed.
  let slots: [ModelSlot]

  /// Why they changed.
  let reason: ModelsGraphChangeReason
}

/// The watch of the disk state of the models of the slots.
///
/// The watch reads the disk only while a subscriber is open: a subscriber
/// takes a base state, and each poll compares the state now with it. The
/// model storage keeps each tree listing in the cache, thus a poll reads the
/// files of the cache and makes no request for a listing that it has.
actor ModelsDiskWatch {
  /// The engine that reads the disk.
  private let engine: ModelsEngine

  /// The open subscribers.
  private var subscribers = 0

  /// The disk state of each model at the last read, by the text form of
  /// the model, or `nil` when no subscriber is open.
  private var last: [String: String]?

  /// Makes the watch.
  ///
  /// - Parameter engine: The engine that reads the disk.
  init(engine: ModelsEngine) {
    self.engine = engine
  }

  /// Adds a subscriber. The first one takes the base state.
  func subscribe() async {
    subscribers += 1
    if last == nil {
      last = await engine.diskFingerprint()
    }
  }

  /// Removes a subscriber. With none open, the watch forgets its state.
  func unsubscribe() {
    subscribers = max(0, subscribers - 1)
    if subscribers == 0 {
      last = nil
    }
  }

  /// Takes the base state again, for example after a slot changed.
  func rebase() async {
    guard subscribers > 0 else {
      return
    }
    last = await engine.diskFingerprint()
  }

  /// Reads the disk state, and gives each model whose state changed since
  /// the last read.
  ///
  /// - Returns: The text forms of the changed models, none when no
  ///   subscriber is open.
  func poll() async -> Set<String> {
    guard subscribers > 0, let old = last else {
      return []
    }
    let now = await engine.diskFingerprint()
    guard subscribers > 0 else {
      return []
    }
    last = now
    return Set(now.keys.filter { now[$0] != old[$0] })
  }
}

/// The one change feed of a `models` endpoint.
final class ModelsGraphChangeFeed: Sendable {
  /// The change log.
  let log: ChangeLog<ModelsGraphChangeEvent>

  /// The disk watch.
  let watch: ModelsDiskWatch

  /// The start of the watch of the settings store: it gives the stream of
  /// the changes of the store when the store watches the user level. A new
  /// subscriber waits for it, thus a slot change after the subscription
  /// starts is never lost.
  let settingsWatch: Task<AsyncStream<SettingsChange>, Never>

  /// The tasks that feed the log. The feed cancels them when it goes.
  private let tasks: Mutex<[Task<Void, Never>]>

  /// Makes the feed and starts its tasks.
  ///
  /// - Parameters:
  ///   - engine: The engine of the endpoint.
  ///   - diskPollInterval: The time between two reads of the disk.
  ///   - capacity: The capacity of the change log.
  init(engine: ModelsEngine, diskPollInterval: Duration, capacity: Int) {
    let log = ChangeLog<ModelsGraphChangeEvent>(capacity: capacity)
    let watch = ModelsDiskWatch(engine: engine)
    self.log = log
    self.watch = watch
    let store = engine.store
    let settingsWatch = Task {
      let changes = await store.changes()
      try? await store.startWatching(cwd: nil)
      return changes
    }
    self.settingsWatch = settingsWatch
    let settings = Task {
      await Self.recordSettingsChanges(
        await settingsWatch.value, into: log, rebasing: watch, clearing: engine.fitCache)
    }
    let disk = Task {
      await Self.recordDiskChanges(
        of: watch, engine: engine, every: diskPollInterval, into: log)
    }
    tasks = Mutex([settings, disk])
  }

  deinit {
    tasks.withLock { $0.forEach { $0.cancel() } }
  }

  /// Tells if a change of the settings can change the selected profile: a
  /// change of `profile.preset`, of the whole profile section, or of a
  /// whole file.
  ///
  /// - Parameter keyPath: The changed key path, or `nil` for a change of a
  ///   whole file.
  /// - Returns: `true` when the selected profile can change.
  static func changesProfile(_ keyPath: [String]?) -> Bool {
    guard let keyPath else {
      return true
    }
    return ProfileConfiguration.presetKeyPath.starts(with: keyPath)
      || keyPath.starts(with: ProfileConfiguration.presetKeyPath)
  }

  /// Logs a change for each change of `profile.preset` at the user level.
  /// The change names each slot, because each slot can have a new model.
  ///
  /// - Parameters:
  ///   - changes: The changes of the settings store.
  ///   - log: The change log.
  ///   - watch: The disk watch, which takes its base state again after a
  ///     profile change.
  ///   - fitCache: The fit estimates, which the change clears.
  private static func recordSettingsChanges(
    _ changes: AsyncStream<SettingsChange>, into log: ChangeLog<ModelsGraphChangeEvent>,
    rebasing watch: ModelsDiskWatch, clearing fitCache: ProfileFitCache
  ) async {
    for await change in changes {
      guard change.level == .user, changesProfile(change.keyPath) else {
        continue
      }
      await fitCache.clear()
      await log.append(ModelsGraphChangeEvent(slots: ModelSlot.allCases, reason: .profile))
      await watch.rebase()
    }
  }

  /// Logs a change when the disk state of a model of a builtin profile
  /// changed, while a subscriber is open. The change names the slots of
  /// the selected profile that hold such a model; it can name none, when
  /// the model is only in other profiles. Each such change changes the
  /// `state` of each profile that has the model.
  ///
  /// - Parameters:
  ///   - watch: The disk watch.
  ///   - engine: The engine, which gives the slots of a model.
  ///   - interval: The time between two reads.
  ///   - log: The change log.
  private static func recordDiskChanges(
    of watch: ModelsDiskWatch, engine: ModelsEngine, every interval: Duration,
    into log: ChangeLog<ModelsGraphChangeEvent>
  ) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: interval)
      } catch {
        return
      }
      let models = await watch.poll()
      if !models.isEmpty {
        let slots = await engine.slots(holding: models)
        await engine.fitCache.clear()
        await log.append(ModelsGraphChangeEvent(slots: slots, reason: .disk))
      }
    }
  }
}

/// The `ModelChange` object.
struct ModelsGraphChange: Sendable {
  /// The cursor that resumes the subscription after this change.
  let cursor: String

  /// The time of the change.
  let at: DateTime

  /// The rows that came: none, because the four slots and the builtin
  /// profiles are always there.
  var added: [ToolkitID] { [] }

  /// The slots that changed, by the name of their key: `standard`, `flash`,
  /// `embedding` or `decision`.
  let changed: [ToolkitID]

  /// The rows that went: none.
  var removed: [ToolkitID] { [] }

  /// Why the slots changed.
  let reason: ModelsGraphChangeReason

  /// When the change takes effect.
  let appliesAt: ModelsGraphChangeApplies

  /// The object of one entry of the log.
  ///
  /// - Parameter entry: The entry.
  init(_ entry: ChangeLogEntry<ModelsGraphChangeEvent>) {
    cursor = entry.cursor
    at = DateTime(entry.at)
    changed = entry.event.slots.map { ToolkitID($0.rawValue) }
    reason = entry.event.reason
    appliesAt = entry.event.reason == .profile ? .nextLaunch : .now
  }
}

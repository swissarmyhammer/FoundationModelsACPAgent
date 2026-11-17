import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

/// The layer of a profile file, highest precedence first.
public enum ProfileLayer: String, Codable, CaseIterable, Sendable {
  /// The project layer: `<cwd>/.<name>/profiles/`.
  case project

  /// The user layer: the `profiles` folder of the user layer of
  /// ``SettingsFolders``.
  case user

  /// The bundled profiles of the library (``BundledProfiles``). They are
  /// read-only.
  case bundled

  /// The layer of a settings level.
  ///
  /// - Parameter level: The level.
  init(_ level: SettingsLevel) {
    switch level {
    case .user: self = .user
    case .session: self = .project
    }
  }
}

/// One profile of the list: the file of the first layer that has the name.
public struct ProfileEntry: Sendable {
  /// The name of the profile.
  public let name: String

  /// The layer of the file.
  public let layer: ProfileLayer

  /// The path of the file.
  public let path: String

  /// The profile, or the error of the file.
  public let result: Result<ProfileDefinition, ProfileFileError>

  /// The profile, or `nil` when the file does not decode.
  public var profile: ProfileDefinition? {
    try? result.get()
  }

  /// The error of the file, or `nil` when it decodes.
  public var error: ProfileFileError? {
    guard case .failure(let error) = result else { return nil }
    return error
  }
}

/// A call of the profile store that it cannot do.
public enum ProfileStoreError: Error, Equatable, Sendable, CustomStringConvertible {
  /// No layer has a profile with the name. `available` is each name that a
  /// layer has.
  case unknownProfile(name: String, available: [String])

  /// The name is not a plain file name: it is empty, starts with a dot, or
  /// holds a `/`.
  case invalidName(String)

  /// The layer has no file of the profile, thus there is nothing to delete.
  case noProfileFile(name: String, layer: ProfileLayer)

  /// The settings folders give no folder for the level.
  case noLayer(SettingsLevel)

  /// A human-readable reason that names the profile.
  public var description: String {
    switch self {
    case .unknownProfile(let name, let available):
      "no profile is named \"\(name)\"; the profiles are: \(available.joined(separator: ", "))"
    case .invalidName(let name):
      "\"\(name)\" is not a profile name: a name is a file name, with no \"/\" and no leading \".\""
    case .noProfileFile(let name, let layer):
      "the \(layer.rawValue) layer has no file of the profile \"\(name)\""
    case .noLayer(let level):
      SettingsStoreError.noLayer(level).description
    }
  }
}

/// One change of the profile files that ``ProfileStore/changes()`` sends.
public struct ProfileChange: Equatable, Sendable {
  /// The level whose profiles changed.
  public let level: SettingsLevel

  /// The profile that a save or a delete changed, or `nil` when a file of
  /// the level changed from outside.
  public let name: String?

  /// Makes a change.
  ///
  /// - Parameters:
  ///   - level: The level whose profiles changed.
  ///   - name: The changed profile, or `nil` for an outside change.
  public init(level: SettingsLevel, name: String?) {
    self.level = level
    self.name = name
  }
}

/// The reads of the profile files: the project layer, the user layer, then
/// the bundled profiles. The first layer that has a name wins, as a whole
/// file, with no merge across layers.
///
/// The folders are the `profiles` folders of the layers of the configuration
/// stack of ``SettingsFolders``. Each read reads the disk at the time of the
/// call, thus it needs no cache and no watch.
public struct ProfileLayers: Sendable {
  /// The settings folders of the host.
  public let settingsFolders: SettingsFolders

  /// Makes the reads over the folders of a host.
  ///
  /// - Parameter settingsFolders: The settings folders of the host.
  public init(settingsFolders: SettingsFolders) {
    self.settingsFolders = settingsFolders
  }

  /// Every available profile, one entry for each name: the file of the
  /// first layer that has it. The bundled names come first, in their
  /// order, then the other names in name order.
  ///
  /// - Parameter cwd: The working directory of the project layer, or `nil`
  ///   for the user layer and the bundled profiles only.
  /// - Returns: The entries.
  public func list(cwd: URL?) -> [ProfileEntry] {
    var seen = Set<String>()
    let entries = (fileEntries(cwd: cwd) + bundledEntries).filter { seen.insert($0.name).inserted }
    let bundled = BundledProfiles.names
    return entries.sorted { lhs, rhs in
      let left = bundled.firstIndex(of: lhs.name) ?? bundled.count
      let right = bundled.firstIndex(of: rhs.name) ?? bundled.count
      return left == right ? lhs.name < rhs.name : left < right
    }
  }

  /// The names of every available profile, in the order of ``list(cwd:)``.
  ///
  /// - Parameter cwd: The working directory of the project layer, or `nil`.
  /// - Returns: The names.
  public func names(cwd: URL?) -> [String] {
    list(cwd: cwd).map(\.name)
  }

  /// The profile of a name: the file of the first layer that has it.
  ///
  /// - Parameters:
  ///   - name: The name of the profile.
  ///   - cwd: The working directory of the project layer, or `nil`.
  /// - Returns: The profile.
  /// - Throws: ``ProfileStoreError/unknownProfile(name:available:)`` when
  ///   no layer has the name; ``ProfileFileError`` when its file does not
  ///   decode.
  public func read(_ name: String, cwd: URL?) throws -> ProfileDefinition {
    let entries = list(cwd: cwd)
    guard let entry = entries.first(where: { $0.name == name }) else {
      throw ProfileStoreError.unknownProfile(name: name, available: entries.map(\.name))
    }
    return try entry.result.get()
  }

  /// The `profiles` folder of a level.
  ///
  /// - Parameter level: The level.
  /// - Returns: The folder, or `nil` when the settings folders give no
  ///   folder for the level.
  public func folder(of level: SettingsLevel) -> URL? {
    let workingDirectory = level.workingDirectory ?? SettingsStore.placeholderDirectory
    return settingsFolders.stack(for: .configuration, workingDirectory: workingDirectory)
      .layers.first { $0.source == level.source }?
      .root.appendingPathComponent(ProfileFile.folderName, isDirectory: true)
  }

  /// The file of a profile at a level.
  ///
  /// - Parameters:
  ///   - name: The name of the profile.
  ///   - level: The level.
  /// - Returns: The file, or `nil` when the level has no folder.
  func file(of name: String, level: SettingsLevel) -> URL? {
    folder(of: level)?.appendingPathComponent(
      "\(name).\(ProfileFile.fileExtension)", isDirectory: false)
  }

  /// The entries of the files of the project layer and then the user layer.
  ///
  /// - Parameter cwd: The working directory of the project layer, or `nil`.
  /// - Returns: The entries, each file of a layer in name order.
  private func fileEntries(cwd: URL?) -> [ProfileEntry] {
    SettingsLevel.watched(cwd: cwd).reversed().flatMap { level in
      folder(of: level).map { entries(in: $0, layer: ProfileLayer(level)) } ?? []
    }
  }

  /// The entries of the profile files of one folder.
  ///
  /// - Parameters:
  ///   - folder: The `profiles` folder.
  ///   - layer: The layer of the folder.
  /// - Returns: The entries in name order; none when there is no folder.
  private func entries(in folder: URL, layer: ProfileLayer) -> [ProfileEntry] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return files.filter { $0.pathExtension == ProfileFile.fileExtension }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { file in
        let name = file.deletingPathExtension().lastPathComponent
        return ProfileEntry(
          name: name, layer: layer, path: file.path,
          result: Result { () throws(ProfileFileError) in
            try ProfileFile.definition(ofText: Self.text(of: file), name: name, path: file.path)
          })
      }
  }

  /// The entries of the bundled profiles.
  private var bundledEntries: [ProfileEntry] {
    BundledProfiles.all.map { profile in
      ProfileEntry(
        name: profile.name, layer: .bundled, path: BundledProfiles.path(of: profile.name),
        result: .success(profile))
    }
  }

  /// The text of a profile file.
  ///
  /// - Parameter file: The file.
  /// - Returns: The text.
  /// - Throws: ``ProfileFileError/unreadable(path:reason:)``.
  private static func text(of file: URL) throws(ProfileFileError) -> String {
    do {
      return try String(contentsOf: file, encoding: .utf8)
    } catch {
      throw .unreadable(path: file.path, reason: error.localizedDescription)
    }
  }
}

/// The profiles of the agent: the reads of ``ProfileLayers``, a save and a
/// delete of the file of a level, and a notice of each change.
///
/// The store has the layers, the folders and the write path of
/// ``SettingsStore``: the user level and the session level of a working
/// directory (``SettingsLevel``) are the user layer and the project layer, a
/// write is an atomic write that makes the folder first, and
/// ``changes()`` gives each change of a save, a delete and an outside write
/// of a watched level (``startWatching(cwd:)``). A bundled profile is
/// read-only: a user or project file of the same name overrides it, and a
/// delete of that file brings the bundled one back.
public actor ProfileStore {
  /// The reads of the profile files.
  public nonisolated let layers: ProfileLayers

  /// The continuation of each open ``changes()`` stream, keyed by a token.
  private nonisolated let subscribers = Mutex<
    [UUID: AsyncStream<ProfileChange>.Continuation]
  >([:])

  /// The watcher of the `profiles` folder of each watched level, keyed by
  /// the path of the folder.
  private var watchers: [String: DotfolderWatcher] = [:]

  /// Makes a store over the folders of a host.
  ///
  /// - Parameter settingsFolders: The settings folders of the host.
  public init(settingsFolders: SettingsFolders) {
    layers = ProfileLayers(settingsFolders: settingsFolders)
  }

  // MARK: - Writes

  /// Saves the text of a profile file to a level, after a decode of the
  /// text checks it. The file keeps the text as it is.
  ///
  /// - Parameters:
  ///   - text: The text of the file.
  ///   - name: The name of the profile.
  ///   - level: The level of the file: the user layer, or the project
  ///     layer of a working directory.
  /// - Throws: ``ProfileStoreError/invalidName(_:)``,
  ///   ``ProfileStoreError/noLayer(_:)``, ``ProfileFileError`` for a text
  ///   that does not decode, or the error of the write. After an error, no
  ///   file changes.
  public func save(text: String, as name: String, level: SettingsLevel) throws {
    let file = try writableFile(of: name, level: level)
    _ = try ProfileFile.definition(ofText: text, name: name, path: file.path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
    send(ProfileChange(level: level, name: name))
  }

  /// Saves a profile to a level, as the text of ``ProfileFile/text(of:)``.
  ///
  /// - Parameters:
  ///   - profile: The profile. Its own name is not written: the name is
  ///     the name of the file.
  ///   - name: The name of the profile.
  ///   - level: The level of the file.
  /// - Throws: What ``save(text:as:level:)`` throws, or the encoding error.
  public func save(_ profile: ProfileDefinition, as name: String, level: SettingsLevel) throws {
    try save(text: ProfileFile.text(of: profile), as: name, level: level)
  }

  /// Deletes the file of a profile at a level. A lower layer with the name
  /// then applies again.
  ///
  /// - Parameters:
  ///   - name: The name of the profile.
  ///   - level: The level of the file.
  /// - Throws: ``ProfileStoreError/invalidName(_:)``,
  ///   ``ProfileStoreError/noLayer(_:)``,
  ///   ``ProfileStoreError/noProfileFile(name:layer:)`` when the level has
  ///   no file of the profile, or the error of the remove.
  public func delete(_ name: String, level: SettingsLevel) throws {
    let file = try writableFile(of: name, level: level)
    guard FileManager.default.fileExists(atPath: file.path) else {
      throw ProfileStoreError.noProfileFile(name: name, layer: ProfileLayer(level))
    }
    try FileManager.default.removeItem(at: file)
    send(ProfileChange(level: level, name: name))
  }

  /// The file of a profile at a level, after the check of the name.
  ///
  /// - Parameters:
  ///   - name: The name of the profile.
  ///   - level: The level.
  /// - Returns: The file.
  /// - Throws: ``ProfileStoreError/invalidName(_:)`` or
  ///   ``ProfileStoreError/noLayer(_:)``.
  private func writableFile(of name: String, level: SettingsLevel) throws -> URL {
    guard Self.isValidName(name) else {
      throw ProfileStoreError.invalidName(name)
    }
    guard let file = layers.file(of: name, level: level) else {
      throw ProfileStoreError.noLayer(level)
    }
    return file
  }

  /// Tells if a name is a plain file name: not empty, with no `/`, and not
  /// starting with a dot.
  ///
  /// - Parameter name: The name.
  /// - Returns: `true` for a valid name.
  static func isValidName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
  }

  // MARK: - Changes

  /// A stream of each change that the store makes or sees from now on.
  ///
  /// - Returns: The stream. It ends when the caller stops to iterate it, or
  ///   when ``stopWatching()`` runs.
  public func changes() -> AsyncStream<ProfileChange> {
    let (stream, continuation) = AsyncStream.makeStream(of: ProfileChange.self)
    let token = UUID()
    subscribers.withLock { $0[token] = continuation }
    continuation.onTermination = { [weak self] _ in
      self?.removeSubscriber(token)
    }
    return stream
  }

  /// Watches the `profiles` folder of the user level and, when `cwd` is
  /// given, of the session level of `cwd`. An outside write of a file in
  /// such a folder sends a change with no name.
  ///
  /// - Parameter cwd: The working directory of the session level, or `nil`
  ///   for the user level only.
  public func startWatching(cwd: URL?) {
    for level in SettingsLevel.watched(cwd: cwd) {
      guard let folder = layers.folder(of: level), watchers[folder.path] == nil else {
        continue
      }
      let watcher = DotfolderWatcher(roots: [folder]) { [weak self] in
        self?.send(ProfileChange(level: level, name: nil))
      }
      watchers[folder.path] = watcher
      watcher.start()
    }
  }

  /// Stops each watcher, and ends each open ``changes()`` stream.
  public func stopWatching() {
    watchers.values.forEach { $0.stop() }
    watchers.removeAll()
    let continuations = subscribers.withLock { subscribers in
      defer { subscribers.removeAll() }
      return Array(subscribers.values)
    }
    continuations.forEach { $0.finish() }
  }

  /// Forgets the continuation of a ``changes()`` stream that ended.
  ///
  /// - Parameter token: The token of the stream.
  private nonisolated func removeSubscriber(_ token: UUID) {
    _ = subscribers.withLock { $0.removeValue(forKey: token) }
  }

  /// Sends a change to each open ``changes()`` stream.
  ///
  /// - Parameter change: The change.
  private nonisolated func send(_ change: ProfileChange) {
    let continuations = subscribers.withLock { Array($0.values) }
    continuations.forEach { $0.yield(change) }
  }
}

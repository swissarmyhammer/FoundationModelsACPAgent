import Foundation
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsSkills
import Synchronization

/// A kind of the library part of the content catalog (D214, part 4). Rules have no kind yet: no
/// reader of rules exists (FoundationModelsRules, D63).
public enum LibraryKind: String, Sendable, Hashable, Codable, CaseIterable {
  /// The agents of the `agents` tool: `<layer>/<id>/AGENT.md`.
  case agent

  /// The skills: `<layer>/<id>/SKILL.md`.
  case skill

  /// The MCP servers of `tools.mcp` in `config.yaml`.
  case mcpServer
}

/// A level of the library: the user level, or the project level of one folder.
public enum LibraryLevel: Sendable, Hashable, Codable {
  /// The user level.
  case user

  /// The project level of this working folder.
  case folder(URL)
}

/// One domain of the library part: one kind at one level.
public struct LibraryDomain: Sendable, Hashable, Codable {
  /// The kind.
  public let kind: LibraryKind

  /// The level.
  public let level: LibraryLevel

  /// Makes a domain.
  ///
  /// - Parameters:
  ///   - kind: The kind.
  ///   - level: The level.
  public init(kind: LibraryKind, level: LibraryLevel) {
    self.kind = kind
    self.level = level
  }
}

/// The id of one library record: its domain and its name.
public struct LibraryRecordID: Sendable, Hashable, Codable {
  /// The domain of the record.
  public let domain: LibraryDomain

  /// The id or the name of the item in its domain.
  public let name: String

  /// Makes an id.
  ///
  /// - Parameters:
  ///   - domain: The domain of the record.
  ///   - name: The id or the name of the item.
  public init(domain: LibraryDomain, name: String) {
    self.domain = domain
    self.name = name
  }
}

/// The record of one agent, skill or MCP server for the content catalog of a host (D214, part
/// 4). An MCP server record holds only its name, its state and the kind of its transport: no
/// command, no argument, no URL, no environment value and no header, because these can hold a
/// secret.
public struct LibraryContentRecord: Sendable, Equatable, Codable, Identifiable {
  /// The id: the domain and the name.
  public let id: LibraryRecordID

  /// The name to show.
  public let displayName: String

  /// The description, or `nil`.
  public let description: String?

  /// The body of an agent or a skill (the text of its file after the frontmatter for an agent,
  /// the whole file for a skill), or `nil` for an MCP server.
  public let body: String?

  /// For an MCP server: whether it is on. For each other kind: `true`.
  public let isEnabled: Bool

  /// For an MCP server: `stdio` or `http`. For each other kind: `nil`.
  public let transportKind: String?

  /// The text of the record for its stamp.
  var stampText: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }
}

/// The library part of the content catalog (D214, part 4): the agents, the skills and the MCP
/// servers at the user level and at the project level of each known folder. A known folder is
/// the working folder of a session of the session directory that the `readableFolder` rule of
/// the host permits.
///
/// A read of a domain (``records(of:)``, ``stamps()``) also starts the watch of that domain, so
/// a later change of its files gives a change on ``changes()``.
public struct LibraryContentCatalog: Sendable {
  /// The settings folders of the agent.
  private let settingsFolders: SettingsFolders

  /// The settings store of the agent, for the MCP servers.
  private let store: SettingsStore

  /// The session directory, for the known folders.
  private let directory: any SessionDirectory

  /// Tells whether the process can read a folder now with no prompt.
  private let readableFolder: @Sendable (URL) -> Bool

  /// The watches of the domains that the host read, and the feed of their changes.
  private let watches: LibraryWatches

  /// Makes the part.
  ///
  /// - Parameters:
  ///   - settingsFolders: The settings folders of the agent.
  ///   - store: The settings store of the agent.
  ///   - directory: The session directory.
  ///   - readableFolder: The folder rule of the host.
  ///   - watches: The watches of the agent.
  init(
    settingsFolders: SettingsFolders, store: SettingsStore, directory: any SessionDirectory,
    readableFolder: @escaping @Sendable (URL) -> Bool, watches: LibraryWatches
  ) {
    self.settingsFolders = settingsFolders
    self.store = store
    self.directory = directory
    self.readableFolder = readableFolder
    self.watches = watches
  }

  /// The stamp of each domain: each kind at the user level and at each known folder.
  ///
  /// - Returns: The stamp of each domain.
  /// - Throws: The error of the session directory.
  public func stamps() async throws -> [LibraryDomain: ContentStamp] {
    var stamps: [LibraryDomain: ContentStamp] = [:]
    for level in try await levels() {
      for kind in LibraryKind.allCases {
        let domain = LibraryDomain(kind: kind, level: level)
        stamps[domain] = ContentStamp.hashing(try await records(of: domain).map(\.stampText))
      }
    }
    return stamps
  }

  /// The records of one domain, in the order of their names. The read starts the watch of the
  /// domain.
  ///
  /// - Parameter domain: The domain.
  /// - Returns: The records, or none for a folder that the rule refuses.
  /// - Throws: The error of a read of a file of the domain.
  public func records(of domain: LibraryDomain) async throws -> [LibraryContentRecord] {
    if case .folder(let folder) = domain.level, !readableFolder(folder) {
      return []
    }
    watch(domain)
    return try await read(domain).sorted { $0.id.name < $1.id.name }
  }

  /// The record of one item.
  ///
  /// - Parameter id: The id of the record.
  /// - Returns: The record, or `nil` when its domain has no such item.
  /// - Throws: The error of a read of a file of the domain.
  public func record(_ id: LibraryRecordID) async throws -> LibraryContentRecord? {
    try await records(of: id.domain).first { $0.id == id }
  }

  /// Makes a new stream of the changes of the domains that the host read. Each call gives a new
  /// stream of its own. A change of the files of a domain gives `changed` with all of its
  /// records, or `domainRemoved` when the domain has no record any more.
  ///
  /// The stream holds the newest changes that its subscriber did not read, and it drops the
  /// oldest ones.
  ///
  /// - Returns: The stream of the changes after this call.
  public func changes() -> AsyncStream<ContentCatalogChange<LibraryDomain, LibraryContentRecord>> {
    watches.feed.subscribe()
  }

  // MARK: - The levels

  /// The user level, then the level of each known folder.
  ///
  /// - Returns: The levels.
  /// - Throws: The error of the session directory.
  private func levels() async throws -> [LibraryLevel] {
    let summaries = try await directory.sessions(
      matching: SessionQuery(includesRecorded: true, limit: .max))
    let folders = Set(summaries.map { $0.workingDirectory.standardizedFileURL })
      .filter(readableFolder)
      .sorted { $0.path < $1.path }
    return [.user] + folders.map(LibraryLevel.folder)
  }

  /// The layer of the files of a kind at a level.
  ///
  /// - Parameters:
  ///   - kind: The settings kind of the files.
  ///   - level: The level.
  /// - Returns: The layer, or `nil` when the stack has no layer of the level.
  private func layer(of kind: SettingsFolders.Kind, at level: LibraryLevel) -> DotfolderStack.Layer? {
    switch level {
    case .user:
      let home = FileManager.default.homeDirectoryForCurrentUser
      return settingsFolders.stack(for: kind, workingDirectory: home).layers.first { $0.source == .user }
    case .folder(let folder):
      return settingsFolders.stack(for: kind, workingDirectory: folder).layers.first {
        $0.source == .project
      }
    }
  }

  // MARK: - The reads

  /// The records of one domain, in no order.
  ///
  /// - Parameter domain: The domain.
  /// - Returns: The records.
  /// - Throws: The error of a read.
  private func read(_ domain: LibraryDomain) async throws -> [LibraryContentRecord] {
    switch domain.kind {
    case .agent:
      guard let layer = layer(of: .agents, at: domain.level) else { return [] }
      let registry = AgentRegistry(layers: [layer])
      try await registry.load()
      return registry.catalog().definitions.map { definition in
        LibraryContentRecord(
          id: LibraryRecordID(domain: domain, name: definition.id),
          displayName: definition.displayName, description: definition.description,
          body: definition.body, isEnabled: true, transportKind: nil)
      }
    case .skill:
      guard let layer = layer(of: .skills, at: domain.level) else { return [] }
      let registry = SkillsRegistry(layers: [layer], mode: .sandboxed)
      return registry.commandListing().map { listing in
        let file = layer.root.appendingPathComponent(listing.id, isDirectory: true)
          .appendingPathComponent("SKILL.md", isDirectory: false)
        return LibraryContentRecord(
          id: LibraryRecordID(domain: domain, name: listing.id),
          displayName: listing.displayName ?? listing.id, description: listing.description,
          body: try? String(contentsOf: file, encoding: .utf8), isEnabled: true,
          transportKind: nil)
      }
    case .mcpServer:
      return try await mcpServers(of: domain)
    }
  }

  /// The MCP servers that the level of `domain` sets in `tools.mcp`. A list of a level replaces
  /// the list of a lower level, so a folder sets servers only when its own file has the list.
  ///
  /// - Parameter domain: An MCP server domain.
  /// - Returns: The records: the name, the state and the kind of the transport only.
  /// - Throws: The error of a level file, or of the decode of the list.
  private func mcpServers(of domain: LibraryDomain) async throws -> [LibraryContentRecord] {
    let keyPath = [
      AgentConfiguration.CodingKeys.tools.stringValue, ToolsConfiguration.CodingKeys.mcp.stringValue,
    ]
    let cwd: URL?
    let level: ConfigurationLayerName
    switch domain.level {
    case .user:
      cwd = nil
      level = .user
    case .folder(let folder):
      cwd = folder
      level = .project
    }
    if let cwd {
      try await store.startWatching(cwd: cwd)
    }
    guard let value = try await store.value(at: keyPath, cwd: cwd), value.level == level,
      case .enabled(let servers) = try value.value.decoded(as: MCPToolSection.self)
    else {
      return []
    }
    return servers.map { server in
      let kind: String
      switch server.transport {
      case .stdio: kind = "stdio"
      case .http: kind = "http"
      }
      return LibraryContentRecord(
        id: LibraryRecordID(domain: domain, name: server.name), displayName: server.name,
        description: nil, body: nil, isEnabled: server.enabled, transportKind: kind)
    }
  }

  // MARK: - The watches

  /// Starts the watch of a domain, one time: a file watch of the layer root for an agent or a
  /// skill domain, a watch of the settings store for an MCP server domain.
  ///
  /// - Parameter domain: The domain.
  private func watch(_ domain: LibraryDomain) {
    let part = self
    let republish: @Sendable () -> Void = {
      Task {
        let records = (try? await part.read(domain))?.sorted { $0.id.name < $1.id.name } ?? []
        part.watches.feed.publish([records.isEmpty ? .domainRemoved(domain) : .changed(domain, records)])
      }
    }
    switch domain.kind {
    case .agent, .skill:
      let kind: SettingsFolders.Kind = domain.kind == .agent ? .agents : .skills
      guard let root = layer(of: kind, at: domain.level)?.root else { return }
      watches.startFileWatch(of: domain, root: root, onChange: republish)
    case .mcpServer:
      watches.startSettingsWatch(of: domain, store: store, onChange: republish)
    }
  }
}

/// The watches of the library domains that the host read, and the feed of their changes. The
/// agent holds one, so a watch lives as long as the agent.
final class LibraryWatches: Sendable {
  /// The feed of the changes.
  let feed = SubscriberFeed<ContentCatalogChange<LibraryDomain, LibraryContentRecord>> {
    ACPAgentTelemetry.logger(.session).warning(
      "A subscriber of the library catalog is slow. It lost its oldest change.")
  }

  /// The file watchers and the settings watch tasks, by domain.
  private let state = Mutex<(files: [LibraryDomain: DotfolderWatcher], settings: [LibraryDomain: Task<Void, Never>])>(
    ([:], [:]))

  /// Starts the file watch of one domain, one time.
  ///
  /// - Parameters:
  ///   - domain: The domain.
  ///   - root: The layer root to watch.
  ///   - onChange: Called after a change of the files.
  func startFileWatch(of domain: LibraryDomain, root: URL, onChange: @escaping @Sendable () -> Void) {
    let watcher = state.withLock { state -> DotfolderWatcher? in
      guard state.files[domain] == nil else { return nil }
      let watcher = DotfolderWatcher(roots: [root], onChange: onChange)
      state.files[domain] = watcher
      return watcher
    }
    watcher?.start()
  }

  /// Starts the settings watch of one MCP server domain, one time: a change of `tools.mcp` or
  /// an outside edit at the level of the domain calls `onChange`.
  ///
  /// - Parameters:
  ///   - domain: The domain.
  ///   - store: The settings store.
  ///   - onChange: Called after a change.
  func startSettingsWatch(
    of domain: LibraryDomain, store: SettingsStore, onChange: @escaping @Sendable () -> Void
  ) {
    state.withLock { state in
      guard state.settings[domain] == nil else { return }
      let changes = store.changes()
      let keyPath = [AgentConfiguration.CodingKeys.tools.stringValue, ToolsConfiguration.CodingKeys.mcp.stringValue]
      state.settings[domain] = Task {
        for await change in changes {
          let atLevel: Bool
          switch (change.level, domain.level) {
          case (.user, .user): atLevel = true
          case (.session(let changed), .folder(let folder)):
            atLevel = changed.standardizedFileURL == folder.standardizedFileURL
          default: atLevel = false
          }
          let reaches =
            change.keyPath.map { keyPath.starts(with: $0) || $0.starts(with: keyPath) } ?? true
          if atLevel, reaches {
            onChange()
          }
        }
      }
    }
  }

  deinit {
    let (files, tasks) = state.withLock { ($0.files.values, $0.settings.values) }
    for watcher in files {
      watcher.stop()
    }
    for task in tasks {
      task.cancel()
    }
  }
}

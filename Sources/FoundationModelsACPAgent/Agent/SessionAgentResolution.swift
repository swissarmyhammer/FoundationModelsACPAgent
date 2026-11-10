import Foundation
import FoundationModelsACP
import FoundationModelsAgents

/// Where the agent of a session comes from (D71).
enum SessionAgentSource: String, Codable, Sendable {
  /// The `agent` option of `session/new`: an agent of the catalog, or
  /// `default`.
  case option

  /// The root `AGENT.md` of the working directory.
  case workingDirectory

  /// The default agent of the catalog, else the builtin floor: the client
  /// gave no option, and the working directory has no valid `AGENT.md`.
  case defaultAgent
}

/// The agent of one session, as the record of the session keeps it, so a
/// resume composes the same agent.
struct SessionAgentChoice: Codable, Equatable, Sendable {
  /// The id of the agent. The id `default` with no default agent is the
  /// builtin floor.
  let id: String

  /// Where the agent comes from.
  let source: SessionAgentSource
}

/// The resolved agent of one session.
struct ResolvedSessionAgent: Sendable {
  /// The choice that the record of the session keeps.
  let choice: SessionAgentChoice

  /// The definition of the agent, or `nil` for the builtin floor.
  let definition: AgentDefinition?

  /// The role of the `AGENT.md` of the working directory in the
  /// instructions of the session.
  var workingDirectoryAgent: InstructionsAssembler.WorkingDirectoryAgent {
    switch choice.source {
    case .option:
      return .projectInstructions
    case .workingDirectory:
      return .sessionAgent
    case .defaultAgent:
      return .alias
    }
  }
}

/// The resolution of the agent of a session (ACPA-1, D71), in this order:
///
/// 1. The `agent` option of `session/new`, through
///    `AgentCatalog.definition(named:)`. The value `default` is the default
///    agent, else the builtin floor.
/// 2. Else the root `AGENT.md` of the working directory, through
///    `AgentRegistry.rootAgent(in:id:)`.
/// 3. Else the default agent of the catalog, else the builtin floor.
///
/// The id of the `AGENT.md` of the working directory:
///
/// - `<name>` when the working directory is the agent folder `<root>/<name>/`
///   or `<root>/agents/<name>/` of a catalog layer (`Agents/<name>/` in the
///   app), and `<name>` is a valid agent id.
/// - `default` when the working directory is the root of a catalog layer:
///   the root settings folder.
/// - Else the id that ``agentID(forFolderNamed:)`` gives for the name of the
///   folder. That id is always valid, also for a name with spaces or other
///   characters that an id does not allow.
enum SessionAgentResolution {
  /// The maximum count of characters in an agent id.
  static let maximumIDLength = 64

  /// The id of a folder whose name has no letter and no digit of the id
  /// alphabet.
  static let fallbackFolderAgentID = "folder"

  /// The character that joins the words of an id.
  private static let separator: Character = "-"

  /// The folder of a catalog layer that holds the agent folders of the
  /// `agents/<name>/` form.
  private static let agentsFolderName = "agents"

  /// The characters of an id other than the separator.
  private static let idCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789")

  // MARK: - The resolution

  /// Resolves the agent of a new session.
  ///
  /// - Parameters:
  ///   - requested: The value of the `agent` option, or `nil` when the
  ///     client gives none.
  ///   - catalog: The agent catalog of the session.
  ///   - workingDirectory: The working directory of the session.
  ///   - layerRoots: The root of each local layer of the agent catalog.
  /// - Returns: The agent of the session.
  /// - Throws: `RequestError.invalidConfigOptionValue(id:)` when no agent
  ///   that a user can start has the id `requested`.
  static func resolve(
    requested: String?, catalog: AgentCatalog, workingDirectory: URL, layerRoots: [URL]
  ) throws -> ResolvedSessionAgent {
    guard let requested else {
      return resolveUnselected(
        catalog: catalog, workingDirectory: workingDirectory, layerRoots: layerRoots)
    }
    guard let agent = catalogAgent(id: requested, source: .option, in: catalog) else {
      throw RequestError.invalidConfigOptionValue(id: ConfigOptions.agentOptionId)
    }
    return agent
  }

  /// Resolves the agent of a resumed session from its record. When the
  /// recorded agent is gone, the session gets the agent that a new session
  /// with no option gets, and a warning goes to the log.
  ///
  /// - Parameters:
  ///   - choice: The recorded choice.
  ///   - catalog: The agent catalog of the session.
  ///   - workingDirectory: The working directory of the session.
  ///   - layerRoots: The root of each local layer of the agent catalog.
  /// - Returns: The agent of the session.
  static func restore(
    _ choice: SessionAgentChoice, catalog: AgentCatalog, workingDirectory: URL,
    layerRoots: [URL]
  ) -> ResolvedSessionAgent {
    let restored: ResolvedSessionAgent?
    switch choice.source {
    case .option, .defaultAgent:
      restored = catalogAgent(id: choice.id, source: choice.source, in: catalog)
    case .workingDirectory:
      restored = workingDirectoryAgent(in: workingDirectory, id: choice.id)
    }
    if let restored {
      return restored
    }
    ACPAgentTelemetry.logger(.sessionResume).warning(
      "The recorded agent of the session is gone. The session gets the agent of a new session.",
      metadata: [ACPAgentTelemetry.LogMetadataKey.agentID: "\(choice.id)"])
    return resolveUnselected(
      catalog: catalog, workingDirectory: workingDirectory, layerRoots: layerRoots)
  }

  /// The agent of a session when the client gives no `agent` option: the
  /// `AGENT.md` of the working directory, else the default agent, else the
  /// builtin floor.
  private static func resolveUnselected(
    catalog: AgentCatalog, workingDirectory: URL, layerRoots: [URL]
  ) -> ResolvedSessionAgent {
    let id = workingDirectoryAgentID(of: workingDirectory, layerRoots: layerRoots)
    if let agent = workingDirectoryAgent(in: workingDirectory, id: id) {
      return agent
    }
    return ResolvedSessionAgent(
      choice: SessionAgentChoice(id: AgentCatalog.defaultAgentID, source: .defaultAgent),
      definition: catalog.defaultAgent)
  }

  /// The catalog agent with the id `id`: `default` gives the default agent,
  /// else the builtin floor; another id gives an agent that a user can
  /// start.
  ///
  /// - Parameters:
  ///   - id: The id of the agent.
  ///   - source: The source of the choice.
  ///   - catalog: The agent catalog.
  /// - Returns: The agent, or `nil` when no agent that a user can start has
  ///   the id.
  private static func catalogAgent(
    id: String, source: SessionAgentSource, in catalog: AgentCatalog
  ) -> ResolvedSessionAgent? {
    let choice = SessionAgentChoice(id: id, source: source)
    guard id != AgentCatalog.defaultAgentID else {
      return ResolvedSessionAgent(choice: choice, definition: catalog.defaultAgent)
    }
    guard let definition = catalog.definition(named: id), definition.isUserInvocable else {
      return nil
    }
    return ResolvedSessionAgent(choice: choice, definition: definition)
  }

  /// The root `AGENT.md` of the working directory as the agent `id`. Each
  /// diagnostic of the read goes to the log as a warning.
  ///
  /// - Parameters:
  ///   - workingDirectory: The working directory of the session.
  ///   - id: The id of the agent.
  /// - Returns: The agent, or `nil` when the folder has no valid `AGENT.md`.
  private static func workingDirectoryAgent(in workingDirectory: URL, id: String)
    -> ResolvedSessionAgent?
  {
    let load = AgentRegistry.rootAgent(in: workingDirectory, id: id)
    for diagnostic in load.diagnostics {
      ACPAgentTelemetry.logger(.session).warning(
        "The AGENT.md of the working directory has a problem: \(diagnostic)")
    }
    return load.definition.map { definition in
      ResolvedSessionAgent(
        choice: SessionAgentChoice(id: id, source: .workingDirectory), definition: definition)
    }
  }

  // MARK: - The id of the working directory

  /// The id of the `AGENT.md` of the working directory: see the rules of
  /// ``SessionAgentResolution``.
  ///
  /// - Parameters:
  ///   - workingDirectory: The working directory of the session.
  ///   - layerRoots: The root of each local layer of the agent catalog.
  /// - Returns: A valid agent id.
  static func workingDirectoryAgentID(of workingDirectory: URL, layerRoots: [URL]) -> String {
    let folder = workingDirectory.canonicalPath
    let roots = Set(layerRoots.map(\.canonicalPath))
    if roots.contains(folder) {
      return AgentCatalog.defaultAgentID
    }
    let name = workingDirectory.lastPathComponent
    let id = agentID(forFolderNamed: name)
    let parent = workingDirectory.deletingLastPathComponent()
    let isCatalogFolder =
      roots.contains(parent.canonicalPath)
      || (parent.lastPathComponent == agentsFolderName
        && roots.contains(parent.deletingLastPathComponent().canonicalPath))
    // A catalog folder keeps its catalog id; a name that is not a valid id
    // is not a catalog agent, and it gets the mapped id as any other folder.
    return isCatalogFolder && id == name ? name : id
  }

  /// Maps a folder name to a valid agent id: lower case, each character
  /// outside `[a-z0-9]` becomes `-`, a run of `-` becomes one, no `-` at the
  /// start or at the end, and at most ``maximumIDLength`` characters. A
  /// valid id maps to itself.
  ///
  /// - Parameter name: The name of the folder.
  /// - Returns: The id, or ``fallbackFolderAgentID`` when the name has no
  ///   character of the id alphabet.
  static func agentID(forFolderNamed name: String) -> String {
    let words = name.lowercased()
      .split { !idCharacters.contains($0) }
      .map(String.init)
    let id = trimmedSeparators(
      String(words.joined(separator: String(separator)).prefix(maximumIDLength)))
    return id.isEmpty ? fallbackFolderAgentID : id
  }

  /// Removes each separator at the start and at the end of `id`.
  ///
  /// - Parameter id: The id to trim.
  /// - Returns: The id with no separator at its ends.
  private static func trimmedSeparators(_ id: String) -> String {
    String(id.drop { $0 == separator }.reversed().drop { $0 == separator }.reversed())
  }

}

/// The record of the agent of each session: one JSON file in the recording
/// folder of the session. `session/new` writes it after the session exists,
/// and a resume reads it, so the resumed session gets the same agent.
enum SessionAgentStore {
  /// The name of the file in the recording folder of the session.
  static let fileName = "session-agent.json"

  /// The recorded agent of a session.
  ///
  /// - Parameters:
  ///   - sessionId: The id of the session.
  ///   - transcriptRoot: The recording root.
  /// - Returns: The recorded choice, or `nil` when the session has no record
  ///   or the record does not read. A record that does not read goes to the
  ///   log.
  static func choice(of sessionId: SessionId, in transcriptRoot: URL) -> SessionAgentChoice? {
    let file = file(of: sessionId, in: transcriptRoot)
    // A missing file is expected: the session was recorded before this store existed.
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    do {
      return try JSONDecoder().decode(SessionAgentChoice.self, from: Data(contentsOf: file))
    } catch {
      ACPAgentTelemetry.logger(.sessionResume).warning(
        "The agent record of the session does not read. The session gets the agent of a new session.",
        metadata: ACPAgentTelemetry.sessionMetadata(sessionId))
      return nil
    }
  }

  /// Records the agent of a new session.
  ///
  /// - Parameters:
  ///   - choice: The agent of the session.
  ///   - sessionId: The id of the session.
  ///   - transcriptRoot: The recording root.
  /// - Throws: The encode or file system error. The caller logs it: a
  ///   session with no record still works.
  static func record(
    _ choice: SessionAgentChoice, for sessionId: SessionId, in transcriptRoot: URL
  ) throws {
    let file = file(of: sessionId, in: transcriptRoot)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(choice).write(to: file, options: .atomic)
  }

  /// The file of one session.
  private static func file(of sessionId: SessionId, in transcriptRoot: URL) -> URL {
    transcriptRoot.appendingPathComponent(sessionId.rawValue, isDirectory: true)
      .appendingPathComponent(fileName)
  }
}

extension URL {
  /// The path of the URL with the symbolic links resolved and the path
  /// standardized, so two spellings of one file compare equal.
  var canonicalPath: String {
    resolvingSymlinksInPath().standardizedFileURL.path
  }
}

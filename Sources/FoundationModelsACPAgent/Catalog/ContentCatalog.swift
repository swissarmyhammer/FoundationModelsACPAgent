import FoundationModelsACP

/// The content catalog of a host (D214): the neutral records of the things that the host can
/// put in Spotlight. This package does not import Core Spotlight. The host makes the items from
/// the records, and it only reads: it cannot change a thing through these values.
///
/// Each part has a stamp for each domain (``ContentStamp``), the records of a domain, one record
/// by its id, and a change stream. The host compares the stamps with the stamps that it keeps,
/// and reads the records only of a domain whose stamp changed.
public struct ContentCatalog: Sendable {
  /// The sessions (part 1): one record for each session of a folder that the host can read.
  public let sessions: SessionContentCatalog

  /// The turns of each session (part 2): its stamps, its turns and its change stream.
  public let turns: TranscriptSearchChanges

  /// The typed sessions of other agents (part 5), for each source with a root.
  public let externalSessions: ExternalSessionContentCatalog

  /// The agents, the skills and the MCP servers of the user level and of each known folder
  /// (part 4). Rules have no records until a reader of rules exists (D63).
  public let library: LibraryContentCatalog

  /// The setting `spotlight.enabled` of each known folder (part 6).
  public let folderSettings: SpotlightFolderSettings

  /// The boards and the tasks of each known folder (part 3), through the source that the host
  /// gives (``RoutedACPAgent/useBoardContentSource(_:)``).
  public let boards: BoardContentCatalog
}

/// One change of a part of the content catalog. A change stream holds the newest changes that
/// its subscriber did not read, and it drops the oldest ones, as ``RoutedACPAgent/turnEnds()``
/// does. A subscriber that lost changes reads the stamps again.
public enum ContentCatalogChange<Domain: Hashable & Sendable, Record: Identifiable & Sendable>:
  Sendable
where Record.ID: Sendable {
  /// These records of the domain are new or changed.
  case changed(Domain, [Record])

  /// The records with these ids went away from the domain.
  case removed(Domain, [Record.ID])

  /// The domain went away with each of its records.
  case domainRemoved(Domain)
}

extension ContentCatalogChange: Equatable where Record: Equatable {}

extension RoutedACPAgent {
  /// The content catalog of this server for its host (D214). The host only reads through it.
  public nonisolated var contentCatalog: ContentCatalog {
    ContentCatalog(
      sessions: SessionContentCatalog(
        directory: sessionDirectory, readableFolder: transcriptSearchIndex.readableFolder,
        removals: contentRemovalFeed),
      turns: transcriptSearchChanges,
      externalSessions: ExternalSessionContentCatalog(index: sessionImporter.index),
      library: LibraryContentCatalog(
        settingsFolders: settingsFolders, store: settingsStore, directory: sessionDirectory,
        readableFolder: transcriptSearchIndex.readableFolder, watches: libraryWatches),
      folderSettings: SpotlightFolderSettings(store: settingsStore),
      boards: BoardContentCatalog(
        directory: sessionDirectory, readableFolder: transcriptSearchIndex.readableFolder,
        source: boardContentSource.source, given: boardContentSource.given))
  }
}

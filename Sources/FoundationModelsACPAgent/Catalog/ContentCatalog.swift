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
      turns: transcriptSearchChanges)
  }
}

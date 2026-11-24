import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMetadataRegistry
import FoundationModelsMultitool

/// One item of the catalog of the transcript search (D207 (b) (1)): a chunk of the transcript of
/// a session, or a session itself.
///
/// The `MetadataSearcher` of the registry reads the block of each item with the default
/// `renderIndexedText(from:)`, `renderEmbeddedText(from:)` and `renderSummaryBlock()`: its BM25,
/// trigram and cosine signals read the whole block, and the registry decides what matches.
///
/// - A **chunk item** holds one chunk of `SessionSearchChunker` of FoundationModelsACP. Its id is
///   `<session id>/<ordinal>`. Its block is the text of the chunk, with the title of a tool call
///   as its first line. The chunk keeps the turn, the kind, the author, the date and the wire ids
///   of its entries with their ranges in the text.
/// - A **session item** holds the facts of one session (``TranscriptSessionMetadata``). Its id is
///   `<session id>/`. Its block is the name, the slug, the tags, the folder, the agent name, the
///   recap and the last summary, one on each line.
/// - An **external item** holds one typed session of another agent, such as Claude Code or Codex,
///   as the index of the external sessions gives it (D212, design section 5.2). Its id is
///   `external:<source>/<id>`. Its block is the index fields: the title, the first prompt, the
///   last prompt, the folder and the branch, one on each line. The item holds no text of a turn,
///   and no item reads a session file.
///
/// The ids are unique for each session id string, also for a session id that holds a "/"
/// (^8qsp7hb). A chunk item id ends with a digit of its ordinal, and a session item id ends with
/// "/", so a chunk item never has the id of a session item. The ordinal holds no "/", so the text
/// after the last "/" of a chunk item id is its ordinal, and the text before it is its session
/// id: two chunk items with the same id have the same session and the same ordinal. A session
/// item id without its last "/" is its session id. The id of the old form, in which the id of a
/// session item was the session id, gave the session item of `a/1` the id of the chunk item 1 of
/// `a`. The id of an external item starts with `external:`, and its session id is its id: no
/// session of the session directory has such an id, so an external item never passes the
/// session filters of a search, and it is never a session result.
public struct TranscriptSearchItem: SearchableMetadata, Codable, Hashable {
  /// What an item holds.
  public enum Content: Hashable, Sendable {
    /// A chunk of the transcript of the session.
    case chunk(SessionSearchChunk)

    /// The facts of the session.
    case session(TranscriptSessionMetadata)

    /// A typed session of another agent, as the index of the external sessions gives it.
    case external(ExternalSessionSummary)

    /// Hashes the content. `ExternalSessionSummary` is not `Hashable`, so an external content
    /// hashes the source and the id of its session and its index fields. Two equal contents
    /// have equal hashes, because the equality compares each fact of the summary.
    ///
    /// - Parameter hasher: The hasher.
    public func hash(into hasher: inout Hasher) {
      switch self {
      case .chunk(let chunk):
        hasher.combine(0)
        hasher.combine(chunk)
      case .session(let metadata):
        hasher.combine(1)
        hasher.combine(metadata)
      case .external(let summary):
        hasher.combine(2)
        hasher.combine(summary.id)
        for field in TranscriptSearchItem.externalFields(of: summary) {
          hasher.combine(field.text)
        }
      }
    }
  }

  /// The text at the start of the id of an external item.
  static let externalIDPrefix = "external:"

  /// The text after the session id in the id of an item: before the ordinal of the chunk in the
  /// id of a chunk item, and at the end of the id of a session item.
  private static let sessionIDTerminator = "/"

  /// The text between two lines of a block.
  private static let lineSeparator = "\n"

  /// The id of the item: `<session id>/<ordinal>` for a chunk item, and `<session id>/` for a
  /// session item. The ids are unique in one catalog, for each session id string.
  public let id: String

  /// The session of the item.
  public let sessionId: SessionId

  /// What the item holds.
  public let content: Content

  /// Makes the chunk item of one chunk of the transcript of a session.
  ///
  /// - Parameters:
  ///   - chunk: The chunk, from `SessionSearchChunker.chunks(of:dates:)`.
  ///   - session: The session of the transcript.
  public init(chunk: SessionSearchChunk, session: SessionId) {
    id = "\(session.rawValue)\(Self.sessionIDTerminator)\(chunk.ordinal)"
    sessionId = session
    content = .chunk(chunk)
  }

  /// Makes the session item of a session.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - metadata: The facts of the session.
  public init(session: SessionId, metadata: TranscriptSessionMetadata) {
    id = session.rawValue + Self.sessionIDTerminator
    sessionId = session
    content = .session(metadata)
  }

  /// Makes the external item of a session of another agent.
  ///
  /// - Parameter summary: The session, as the index of the external sessions gives it.
  public init(external summary: ExternalSessionSummary) {
    id = Self.externalID(of: summary.id)
    sessionId = SessionId(rawValue: id)
    content = .external(summary)
  }

  /// The id of the external item of a session of another agent: `external:<source>/<id>`.
  ///
  /// - Parameter session: The source and the id of the session.
  /// - Returns: The id.
  static func externalID(of session: ExternalSessionID) -> String {
    "\(externalIDPrefix)\(session.source)\(sessionIDTerminator)\(session.sourceID)"
  }

  /// Renders the item to the text of its search surface: the text of a chunk, with the title of
  /// a tool call as its first line, the facts of a session, one on each line, or the index
  /// fields of a session of another agent, one on each line.
  ///
  /// - Returns: The block.
  public func renderBlock() -> String {
    switch content {
    case .chunk(let chunk):
      return Self.block(of: chunk)
    case .session(let metadata):
      return metadata.blockLines.joined(separator: Self.lineSeparator)
    case .external(let summary):
      return Self.externalFields(of: summary).map(\.text).joined(separator: Self.lineSeparator)
    }
  }

  /// The index fields of a session of another agent, in the order of the lines of its block:
  /// the title, the first prompt, the last prompt, the folder and the branch. A field that the
  /// session does not have is an empty text, so each field always has the same line.
  ///
  /// - Parameter summary: The session.
  /// - Returns: The name of each field, as ``ExternalSessionSearchResult/field`` gives it, with
  ///   its text.
  static func externalFields(of summary: ExternalSessionSummary) -> [(name: String, text: String)]
  {
    [
      (ExternalSessionSearchResult.titleField, summary.title ?? ""),
      (ExternalSessionSearchResult.firstPromptField, summary.firstPrompt ?? ""),
      (ExternalSessionSearchResult.lastPromptField, summary.lastPrompt ?? ""),
      (ExternalSessionSearchResult.folderField, summary.cwd?.path ?? ""),
      (ExternalSessionSearchResult.branchField, summary.gitBranch ?? ""),
    ]
  }

  /// The block of a chunk: its text, with the title of a tool call as its first line. The first
  /// piece of a tool call holds its title as its first line already. A later piece of a long tool
  /// call does not, so its block gets the title.
  ///
  /// - Parameter chunk: The chunk.
  /// - Returns: The block.
  private static func block(of chunk: SessionSearchChunk) -> String {
    let firstLine = chunk.text.prefix { !$0.isNewline }
    guard chunk.kind == .tool, !chunk.title.isEmpty, firstLine != chunk.title else {
      return chunk.text
    }
    return chunk.title + lineSeparator + chunk.text
  }

  // MARK: - Coding

  /// The keys of the coded form. The id is not coded: the decode makes it again from the session
  /// and the content.
  private enum CodingKeys: String, CodingKey {
    /// The session id.
    case sessionId
    /// The chunk of a chunk item.
    case chunk
    /// The facts of a session item.
    case session
    /// The session of another agent of an external item.
    case external
  }

  /// Decodes an item from the form that ``encode(to:)`` writes.
  ///
  /// - Parameter decoder: The decoder.
  /// - Throws: `DecodingError` when the form has no chunk, no facts and no external session, or
  ///   when a chunk does not read.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let summary = try container.decodeIfPresent(ExternalSessionSummary.self, forKey: .external) {
      self.init(external: summary)
      return
    }
    let session = try container.decode(SessionId.self, forKey: .sessionId)
    if let chunk = try container.decodeIfPresent(CodedChunk.self, forKey: .chunk) {
      self.init(chunk: try chunk.chunk(codingPath: container.codingPath), session: session)
      return
    }
    guard
      let metadata = try container.decodeIfPresent(TranscriptSessionMetadata.self, forKey: .session)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .session, in: container,
        debugDescription: "A transcript search item holds no chunk and no session facts.")
    }
    self.init(session: session, metadata: metadata)
  }

  /// Encodes the session and the content of the item.
  ///
  /// - Parameter encoder: The encoder.
  /// - Throws: Whatever the encoder throws.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionId, forKey: .sessionId)
    switch content {
    case .chunk(let chunk):
      try container.encode(CodedChunk(chunk), forKey: .chunk)
    case .session(let metadata):
      try container.encode(metadata, forKey: .session)
    case .external(let summary):
      try container.encode(summary, forKey: .external)
    }
  }
}

/// The coded form of a `SessionSearchChunk`: the kind as its raw value, and each entry id as its
/// text form (`SessionEntry.ID.searchHitID`) with the bounds of its range.
private struct CodedChunk: Codable {
  /// The coded form of one entry of a chunk with its range.
  struct CodedEntryRange: Codable {
    /// The text form of the entry id.
    let entry: String
    /// The lower bound of the range, in characters.
    let lower: Int
    /// The upper bound of the range, in characters.
    let upper: Int
  }

  /// The turn of the chunk.
  let turn: Int
  /// The place of the chunk in the session.
  let ordinal: Int
  /// The raw value of the kind of the chunk.
  let kind: String
  /// The sender of a message from another session, or `nil`.
  let author: String?
  /// The date of the chunk, or `nil`.
  let date: Date?
  /// The title of a tool call.
  let title: String
  /// The text of the chunk.
  let text: String
  /// The entries of the chunk with their ranges.
  let entries: [CodedEntryRange]

  /// Makes the coded form of a chunk.
  ///
  /// - Parameter chunk: The chunk.
  init(_ chunk: SessionSearchChunk) {
    turn = chunk.turn
    ordinal = chunk.ordinal
    kind = chunk.kind.rawValue
    author = chunk.author
    date = chunk.date
    title = chunk.title
    text = chunk.text
    entries = chunk.entries.map { range in
      CodedEntryRange(
        entry: range.id.searchHitID, lower: range.range.lowerBound, upper: range.range.upperBound)
    }
  }

  /// The chunk of this coded form.
  ///
  /// - Parameter codingPath: The coding path of the form, for the error.
  /// - Returns: The chunk.
  /// - Throws: `DecodingError` when the kind, an entry id or a range does not read.
  func chunk(codingPath: [any CodingKey]) throws -> SessionSearchChunk {
    guard let kind = SessionSearchChunk.Kind(rawValue: kind) else {
      throw Self.corrupted("The kind \(kind) of a chunk is not known.", codingPath: codingPath)
    }
    return SessionSearchChunk(
      turn: turn, ordinal: ordinal, kind: kind, author: author, date: date, title: title,
      text: text, entries: try entries.map { try Self.entryRange(of: $0, codingPath: codingPath) })
  }

  /// The entry range of a coded entry.
  ///
  /// - Parameters:
  ///   - coded: The coded entry.
  ///   - codingPath: The coding path of the form, for the error.
  /// - Returns: The entry range.
  /// - Throws: `DecodingError` when the entry id or the range does not read.
  private static func entryRange(of coded: CodedEntryRange, codingPath: [any CodingKey]) throws
    -> SessionSearchChunk.EntryRange
  {
    guard let id = SessionEntry.ID(searchHitID: coded.entry) else {
      throw corrupted(
        "The entry id \(coded.entry) of a chunk is not known.", codingPath: codingPath)
    }
    guard coded.lower <= coded.upper else {
      throw corrupted(
        "The range of the entry \(coded.entry) ends before it starts.", codingPath: codingPath)
    }
    return SessionSearchChunk.EntryRange(id: id, range: coded.lower..<coded.upper)
  }

  /// The error of a coded chunk that does not read.
  ///
  /// - Parameters:
  ///   - description: What does not read.
  ///   - codingPath: The coding path of the form.
  /// - Returns: The error.
  private static func corrupted(_ description: String, codingPath: [any CodingKey]) -> DecodingError
  {
    .dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: description))
  }
}

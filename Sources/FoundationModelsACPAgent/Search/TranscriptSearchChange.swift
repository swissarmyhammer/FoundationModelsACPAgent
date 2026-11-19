import Foundation
import FoundationModelsACP

/// One turn of a session that the transcript search index holds (D207 (i)), for a host that
/// writes the turns to an index of its own, for example Core Spotlight.
///
/// The turn gives the text of each chunk with its kind. This package does not import Core
/// Spotlight and applies no rule to the kinds: the host selects the kinds that it writes (Q71:
/// no tool output and no thoughts).
public struct TranscriptSearchTurn: Sendable, Hashable {
  /// The text of one chunk of a turn, with its kind.
  public struct Chunk: Sendable, Hashable {
    /// The kind of the chunk: a user prompt, agent text, a message between sessions, a tool
    /// call, a plan or a thought.
    public let kind: SessionSearchChunk.Kind

    /// The text of the chunk.
    public let text: String

    /// Makes the text of a chunk with its kind.
    ///
    /// - Parameters:
    ///   - kind: The kind of the chunk.
    ///   - text: The text of the chunk.
    public init(kind: SessionSearchChunk.Kind, text: String) {
      self.kind = kind
      self.text = text
    }
  }

  /// The session of the turn.
  public let sessionId: SessionId

  /// The index of the turn in the session. It is 0 for the entries before the first prompt.
  public let turn: Int

  /// The date of the turn: the first date of its chunks, or `nil` when no chunk has a date.
  public let date: Date?

  /// The chunks of the turn, in the order of the transcript.
  public let chunks: [Chunk]

  /// Makes a turn.
  ///
  /// - Parameters:
  ///   - sessionId: The session of the turn.
  ///   - turn: The index of the turn in the session.
  ///   - date: The date of the turn, or `nil`.
  ///   - chunks: The chunks of the turn, in the order of the transcript.
  public init(sessionId: SessionId, turn: Int, date: Date?, chunks: [Chunk]) {
    self.sessionId = sessionId
    self.turn = turn
    self.date = date
    self.chunks = chunks
  }

  /// The turns of the chunks of one session, in the order of the turns.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - chunks: The chunks of the session, in the order of the transcript.
  /// - Returns: One turn for each turn index of the chunks.
  static func turns(of session: SessionId, chunks: [SessionSearchChunk]) -> [TranscriptSearchTurn] {
    Dictionary(grouping: chunks, by: \.turn).sorted { $0.key < $1.key }.map { turn, chunks in
      TranscriptSearchTurn(
        sessionId: session, turn: turn, date: chunks.lazy.compactMap(\.date).first,
        chunks: chunks.map { Chunk(kind: $0.kind, text: $0.text) })
    }
  }
}

/// One change of the transcript search index (D207 (i)), after the index applied it.
public enum TranscriptSearchChange: Sendable, Hashable {
  /// The index holds new chunks for a session. The change gives each turn of the session, so
  /// the host can replace the items of the session.
  case indexed(session: SessionId, turns: [TranscriptSearchTurn])

  /// The index removed each item of a session.
  case removed(session: SessionId)
}

/// The subscribers of the changes of one index. Each subscriber gets its own stream.
///
/// The index never waits for a subscriber: a subscriber that falls behind by more than
/// ``SubscriberFeed/bufferLimit`` changes loses the oldest ones, and the feed logs each lost
/// change. That subscriber can read the full state again with
/// ``TranscriptSearchIndex/allTurns()``.
typealias TranscriptSearchChangeFeed = SubscriberFeed<TranscriptSearchChange>

extension SubscriberFeed where Element == TranscriptSearchChange {
  /// Makes a feed of the changes of an index with no subscriber. The feed logs each change that
  /// a slow subscriber lost.
  ///
  /// - Parameter bufferLimit: The number of changes that the stream of one subscriber holds.
  convenience init(bufferLimit: Int = defaultBufferLimit) {
    self.init(bufferLimit: bufferLimit) {
      ACPAgentTelemetry.logger(.transcriptSearch).warning(
        "A subscriber of the transcript search changes is slow. It lost its oldest change.")
    }
  }
}

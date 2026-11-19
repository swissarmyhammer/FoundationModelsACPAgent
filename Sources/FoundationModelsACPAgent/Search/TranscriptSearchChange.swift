import Foundation
import FoundationModelsACP
import Synchronization

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
/// The buffer policy of each stream is `.bufferingNewest(bufferLimit)`. The index never waits
/// for a subscriber: a subscriber that falls behind by more than ``bufferLimit`` changes loses
/// the oldest ones, and the feed logs each lost change. That subscriber can read the full state
/// again with ``TranscriptSearchIndex/allTurns()``.
final class TranscriptSearchChangeFeed: Sendable {
  /// The streams of the subscribers, by the number of each subscriber.
  private struct Subscribers {
    /// The number of the next subscriber.
    var nextNumber = 0

    /// The input of the stream of each subscriber, by its number.
    var continuations: [Int: AsyncStream<TranscriptSearchChange>.Continuation] = [:]
  }

  /// The number of changes that the stream of one subscriber holds when the subscriber does not
  /// read them, by default.
  static let defaultBufferLimit = 1024

  /// The number of changes that the stream of one subscriber holds.
  let bufferLimit: Int

  /// The streams of the subscribers.
  private let subscribers = Mutex(Subscribers())

  /// Makes a feed with no subscriber.
  ///
  /// - Parameter bufferLimit: The number of changes that the stream of one subscriber holds.
  init(bufferLimit: Int = defaultBufferLimit) {
    self.bufferLimit = bufferLimit
  }

  /// Makes the stream of a new subscriber.
  ///
  /// - Returns: The stream. It gives each change after this call.
  func subscribe() -> AsyncStream<TranscriptSearchChange> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: TranscriptSearchChange.self, bufferingPolicy: .bufferingNewest(bufferLimit))
    let number = subscribers.withLock { subscribers in
      let number = subscribers.nextNumber
      subscribers.nextNumber += 1
      subscribers.continuations[number] = continuation
      return number
    }
    continuation.onTermination = { [weak self] _ in
      self?.unsubscribe(number)
    }
    return stream
  }

  /// Ends the stream of each subscriber, so a subscriber that reads it stops.
  deinit {
    for continuation in subscribers.withLock({ $0.continuations.values }) {
      continuation.finish()
    }
  }

  /// Gives changes to each subscriber, in order. The call never waits.
  ///
  /// - Parameter changes: The changes.
  func publish(_ changes: [TranscriptSearchChange]) {
    let continuations = subscribers.withLock { Array($0.continuations.values) }
    for continuation in continuations {
      for change in changes {
        if case .dropped = continuation.yield(change) {
          ACPAgentTelemetry.logger(.transcriptSearch).warning(
            "A subscriber of the transcript search changes is slow. It lost its oldest change.")
        }
      }
    }
  }

  /// Removes the stream of a subscriber that ended.
  ///
  /// - Parameter number: The number of the subscriber.
  private func unsubscribe(_ number: Int) {
    subscribers.withLock { _ = $0.continuations.removeValue(forKey: number) }
  }
}

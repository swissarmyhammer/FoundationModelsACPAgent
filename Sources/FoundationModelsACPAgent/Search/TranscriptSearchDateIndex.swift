import Foundation
import FoundationModelsACP
import FoundationModelsMultitool

/// The chunk items of a ``TranscriptSearchIndex`` in the newest-first order of a query with only
/// tokens (D207 (c), ^w0dheny). The index keeps it current on each change of its sessions, so
/// a query with only tokens sorts nothing: it walks the entries from the start, and it stops
/// when it has the sessions of its page.
///
/// The order: the later date first, a chunk with no date last, then the later session id, then
/// the later chunk ordinal.
struct TranscriptSearchDateIndex: Sendable {
  /// One chunk item of the index: the facts that the cheap filters read, and the place of the
  /// item in its session.
  struct Entry: Hashable, Sendable {
    /// The session of the chunk.
    let sessionId: SessionId

    /// The place of the chunk item in the chunk items of its session.
    let position: Int

    /// The ordinal of the chunk in its session.
    let ordinal: Int

    /// The kind of a hit of the chunk.
    let kind: SessionSearchHit.Kind

    /// The date of the chunk, or `nil`.
    let date: Date?

    /// Tells whether this entry comes before another in the newest-first order.
    ///
    /// - Parameter other: Another entry.
    /// - Returns: `true` when this entry comes first.
    func isNewer(than other: Entry) -> Bool {
      let date = date ?? .distantPast
      let otherDate = other.date ?? .distantPast
      guard date == otherDate else {
        return date > otherDate
      }
      guard sessionId == other.sessionId else {
        return sessionId.rawValue > other.sessionId.rawValue
      }
      guard ordinal == other.ordinal else {
        return ordinal > other.ordinal
      }
      return position > other.position
    }
  }

  /// The number of removed and inserted entries above which a change builds the order again
  /// in one pass, and not with one binary search for each entry.
  private static let largeChangeSize = 256

  /// The entries, newest first.
  private(set) var entries: [Entry] = []

  /// Makes an index with no entry.
  init() {}

  /// Makes the index of the chunk items of sessions.
  ///
  /// - Parameter sessions: The sessions, by session id.
  init(sessions: [SessionId: TranscriptSearchIndex.IndexedSession]) {
    entries = Self.sorted(
      sessions.flatMap { Self.entries(of: $0.key, chunkItems: $0.value.chunkItems) })
  }

  /// The entries of the chunk items of one session, in the order of the chunk items. An item
  /// that is not a chunk gives no entry.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - chunkItems: The chunk items of the session.
  /// - Returns: The entries.
  static func entries(of session: SessionId, chunkItems: [TranscriptSearchItem]) -> [Entry] {
    chunkItems.enumerated().compactMap { position, item in
      guard case .chunk(let chunk) = item.content else {
        return nil
      }
      return Entry(
        sessionId: session, position: position, ordinal: chunk.ordinal,
        kind: TranscriptSearchCandidate.kind(of: chunk.kind), date: chunk.date)
    }
  }

  /// Entries in the newest-first order.
  ///
  /// - Parameter entries: The entries.
  /// - Returns: The entries, newest first.
  static func sorted(_ entries: [Entry]) -> [Entry] {
    entries.sorted { $0.isNewer(than: $1) }
  }

  /// Removes entries and inserts other entries, and keeps the order. A small change finds the
  /// place of each entry with a binary search. A large change, as a load or a reconcile, builds
  /// the order again in one pass.
  ///
  /// - Parameters:
  ///   - removed: The entries to remove. An entry that the index does not hold changes nothing.
  ///   - inserted: The entries to insert.
  mutating func replace(_ removed: [Entry], with inserted: [Entry]) {
    guard removed.count + inserted.count <= Self.largeChangeSize else {
      let gone = Set(removed)
      entries = Self.merged(entries.filter { !gone.contains($0) }, Self.sorted(inserted))
      return
    }
    for entry in removed {
      let place = insertionPlace(of: entry)
      if place < entries.count, entries[place] == entry {
        entries.remove(at: place)
      }
    }
    for entry in inserted {
      entries.insert(entry, at: insertionPlace(of: entry))
    }
  }

  /// The place of the first entry that does not come before an entry: the place to insert the
  /// entry, or the place of the same entry.
  ///
  /// - Parameter entry: The entry.
  /// - Returns: The place.
  private func insertionPlace(of entry: Entry) -> Int {
    var lower = 0
    var upper = entries.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if entries[middle].isNewer(than: entry) {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  /// Two lists of entries in the newest-first order as one list in that order.
  ///
  /// - Parameters:
  ///   - first: A list in the newest-first order.
  ///   - second: Another list in the newest-first order.
  /// - Returns: The entries of the two lists, newest first.
  private static func merged(_ first: [Entry], _ second: [Entry]) -> [Entry] {
    var merged: [Entry] = []
    merged.reserveCapacity(first.count + second.count)
    var firstPlace = 0
    var secondPlace = 0
    while firstPlace < first.count, secondPlace < second.count {
      if second[secondPlace].isNewer(than: first[firstPlace]) {
        merged.append(second[secondPlace])
        secondPlace += 1
      } else {
        merged.append(first[firstPlace])
        firstPlace += 1
      }
    }
    merged += first[firstPlace...]
    merged += second[secondPlace...]
    return merged
  }
}

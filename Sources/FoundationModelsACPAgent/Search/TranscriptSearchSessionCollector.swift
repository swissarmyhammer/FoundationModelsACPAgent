import Foundation
import FoundationModelsACP
import FoundationModelsMultitool
import FoundationModelsRouter

/// The sessions of one search, in the order of the search (D207 (c), ^w0dheny).
///
/// The search gives the collector its items in the order of the search. The order of a session
/// is the place of its first item that passes each filter. The sessions of the preferred folder
/// come first (D199 (d)), then the other sessions.
///
/// A page needs only the first sessions of each group: the sessions before the page, the
/// sessions of the page, and one more session to tell that a next page exists. Thus the
/// collector keeps at most `wanted` sessions in each group, and it ignores each later session
/// of a full group. Such a session needs no session filter, no text filter, no candidate and no
/// count. The collector applies the session filters to a session only when its first item
/// comes and a group can still take it.
struct TranscriptSearchSessionCollector {
  /// One session that the collector keeps.
  struct CollectedSession {
    /// The id of the session. It can be any string (^bm6spcd).
    let id: SessionId

    /// The folder of the session.
    let folder: URL

    /// The number of items of the session that passed each filter.
    private(set) var hitCount: Int

    /// The first items of the session that passed each filter, the best first.
    private(set) var candidates: [TranscriptSearchCandidate]

    /// The score of the session: the score of its first item.
    var score: Double {
      candidates.first?.score ?? .zero
    }

    /// Makes a session with its first item.
    ///
    /// - Parameters:
    ///   - id: The id of the session.
    ///   - folder: The folder of the session.
    ///   - candidate: The first item of the session that passed each filter.
    fileprivate init(id: SessionId, folder: URL, candidate: TranscriptSearchCandidate) {
      self.id = id
      self.folder = folder
      hitCount = 1
      candidates = [candidate]
    }

    /// Counts one more item of the session, and keeps it when the session has fewer than
    /// `limit` items.
    ///
    /// - Parameters:
    ///   - candidate: The item.
    ///   - limit: The most items to keep.
    fileprivate mutating func add(_ candidate: TranscriptSearchCandidate, keeping limit: Int) {
      hitCount += 1
      if candidates.count < limit {
        candidates.append(candidate)
      }
    }

    /// The same session with all of its items: the count of the items and the first `limit`.
    ///
    /// - Parameters:
    ///   - all: Each item of the session that passed each filter, the best first. Not empty.
    ///   - limit: The most items to keep.
    /// - Returns: The session.
    func replacingCandidates(with all: [TranscriptSearchCandidate], keeping limit: Int)
      -> CollectedSession
    {
      var session = self
      session.hitCount = all.count
      session.candidates = Array(all.prefix(limit))
      return session
    }
  }

  /// The state of a visible session in the collector.
  private enum Standing {
    /// No item of the session came yet.
    case unseen

    /// The session passed the session filters, and no item of it passed each filter yet.
    case admitted(isPreferred: Bool)

    /// The collector keeps the session at a place of its group.
    case collected(isPreferred: Bool, place: Int)

    /// The session did not pass the session filters, or its group was full when its first item
    /// came: the page does not need it.
    case ignored
  }

  /// One session that the session directory shows.
  private struct Slot {
    /// The id of the session.
    let id: SessionId

    /// The facts of the session in the directory.
    let visible: TranscriptSearchVisibleSession

    /// The state of the session in the collector.
    var standing = Standing.unseen
  }

  /// The filters of the search.
  private let filter: TranscriptSearchFilter

  /// The most sessions that the collector keeps in each group.
  private let wanted: Int

  /// The most items that the collector keeps for each session.
  private let keptHits: Int

  /// True to count each later item of a kept session. A query with only tokens counts the items
  /// of the sessions of its page after its walk.
  private let countsHits: Bool

  /// The comparable path of the preferred folder, or `nil` with no preferred folder.
  private let preferredPath: String?

  /// The place of each slot, by the raw value of its session id.
  private let places: [String: Int]

  /// The sessions that the session directory shows.
  private var slots: [Slot]

  /// The kept sessions of the preferred folder, in their order.
  private var preferred: [CollectedSession] = []

  /// The other kept sessions, in their order.
  private var others: [CollectedSession] = []

  /// Makes a collector over the visible sessions of a filter.
  ///
  /// - Parameters:
  ///   - filter: The filters of the search, with the visible sessions.
  ///   - wanted: The most sessions to keep in each group.
  ///   - keptHits: The most items to keep for each session.
  ///   - countsHits: True to count each later item of a kept session.
  ///   - preferredFolder: The folder whose sessions come first, or `nil`.
  init(
    filter: TranscriptSearchFilter, wanted: Int, keptHits: Int, countsHits: Bool,
    preferredFolder: URL?
  ) {
    let slots = filter.visibleSessions.map { Slot(id: $0.key, visible: $0.value) }
    places = Dictionary(uniqueKeysWithValues: slots.indices.map { (slots[$0].id.rawValue, $0) })
    self.slots = slots
    self.filter = filter
    self.wanted = wanted
    self.keptHits = keptHits
    self.countsHits = countsHits
    preferredPath = preferredFolder.map(Self.comparablePath(of:))
  }

  /// The kept sessions in the order of the search: the sessions of the preferred folder first.
  var sessions: [CollectedSession] {
    preferred + others
  }

  /// True when the walk can stop: no later item can change the kept sessions. A collector that
  /// counts the items of its sessions is never complete, because a later item can change a
  /// count. With a preferred folder, a later session of the preferred folder can still come
  /// before each other session, so only a full preferred group completes the walk.
  var isComplete: Bool {
    guard !countsHits else {
      return false
    }
    return preferred.count >= wanted || (preferredPath == nil && others.count >= wanted)
  }

  /// The slot of a visible session.
  ///
  /// - Parameter session: The session.
  /// - Returns: The slot, or `nil` when the directory does not show the session.
  func slot(of session: SessionId) -> Int? {
    places[session.rawValue]
  }

  /// Tells whether an item of a slot can change the kept sessions. The first item of a session
  /// applies the session filters, and marks the session as ignored when it does not pass them
  /// or when its group is full.
  ///
  /// - Parameter slot: The slot of the session of the item.
  /// - Returns: `true` when the search must apply the other filters and then call
  ///   ``collect(_:at:)``.
  mutating func wants(slot: Int) -> Bool {
    switch slots[slot].standing {
    case .ignored:
      return false
    case .collected:
      return countsHits
    case .admitted(let isPreferred):
      guard count(isPreferred: isPreferred) < wanted else {
        slots[slot].standing = .ignored
        return false
      }
      return true
    case .unseen:
      guard hasRoom, let admitted = admission(of: slot)
      else {
        slots[slot].standing = .ignored
        return false
      }
      slots[slot].standing = admitted
      return wants(slot: slot)
    }
  }

  /// Collects an item of a slot that passed each filter: the first item of a new session, or a
  /// later item of a kept session. Call it only after ``wants(slot:)`` gave `true`.
  ///
  /// - Parameters:
  ///   - candidate: The item.
  ///   - slot: The slot of the session of the item.
  mutating func collect(_ candidate: TranscriptSearchCandidate, at slot: Int) {
    switch slots[slot].standing {
    case .collected(let isPreferred, let place) where isPreferred:
      preferred[place].add(candidate, keeping: keptHits)
    case .collected(_, let place):
      others[place].add(candidate, keeping: keptHits)
    case .admitted(let isPreferred):
      let session = CollectedSession(
        id: slots[slot].id, folder: slots[slot].visible.folder, candidate: candidate)
      slots[slot].standing = .collected(
        isPreferred: isPreferred, place: count(isPreferred: isPreferred))
      if isPreferred {
        preferred.append(session)
      } else {
        others.append(session)
      }
    case .unseen, .ignored:
      assertionFailure("the search collected an item of a session that it did not want")
      ACPAgentTelemetry.logger(.transcriptSearch).error(
        "The transcript search collected an item of a session that its page does not need.",
        metadata: ACPAgentTelemetry.sessionMetadata(slots[slot].id))
    }
  }

  /// True when a group can take one more session. With no preferred folder, each session goes
  /// to the group of the other sessions.
  private var hasRoom: Bool {
    others.count < wanted || (preferredPath != nil && preferred.count < wanted)
  }

  /// The number of kept sessions of a group.
  ///
  /// - Parameter isPreferred: True for the group of the preferred folder.
  /// - Returns: The number of kept sessions.
  private func count(isPreferred: Bool) -> Int {
    isPreferred ? preferred.count : others.count
  }

  /// The session filters on the session of a slot, and its group.
  ///
  /// - Parameter slot: The slot.
  /// - Returns: The admitted state of the session, or `nil` when it does not pass.
  private func admission(of slot: Int) -> Standing? {
    let session = slots[slot]
    guard filter.admits(session.id, visible: session.visible) else {
      return nil
    }
    let isPreferred = preferredPath.map { Self.comparablePath(of: session.visible.folder) == $0 }
    return .admitted(isPreferred: isPreferred ?? false)
  }

  /// The path of a folder to compare two folders: the standard file path.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The path.
  private static func comparablePath(of folder: URL) -> String {
    folder.standardizedFileURL.path
  }
}

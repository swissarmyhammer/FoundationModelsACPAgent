import ACPImport
import Foundation

/// The two levels of the read queue of ``ExternalSessionIndex`` (D212, section 4.3).
enum ExternalSessionReadLevel: Sendable, Equatable {
  /// Level 1: the files of a folder that a client asks for now.
  case folder

  /// Level 2: each other file.
  case background
}

/// The read queue of Step B: two levels, and the newest file first in each level. A worker
/// takes each file of level 1 before a file of level 2.
///
/// The queue keeps one place for each file. A file that moves to the other level keeps its
/// old place in the order of its old level, and the queue skips that place when it reaches it.
struct ExternalSessionReadQueue: Sendable {
  /// One place in the order of a level.
  private struct Place: Sendable {
    /// The file.
    let key: ExternalSessionFileKey

    /// The modification date of the file, for the order.
    let modified: Date
  }

  /// The order of one level, the newest file last, and true when a new place is not sorted.
  private struct Order: Sendable {
    /// The places, the newest last after a sort.
    var places: [Place] = []

    /// True when a place was added after the last sort.
    var needsSort = false

    /// Adds a place.
    mutating func append(_ place: Place) {
      places.append(place)
      needsSort = true
    }

    /// Takes the newest place.
    mutating func popNewest() -> Place? {
      if needsSort {
        places.sort { first, second in
          first.modified == second.modified
            ? first.key.path > second.key.path : first.modified < second.modified
        }
        needsSort = false
      }
      return places.popLast()
    }
  }

  /// The level of each file in the queue.
  private var levels: [ExternalSessionFileKey: ExternalSessionReadLevel] = [:]

  /// The project key of each file in the queue, for a move between the levels.
  private var projectKeys: [ExternalSessionFileKey: String] = [:]

  /// The order of level 1.
  private var folderOrder = Order()

  /// The order of level 2.
  private var backgroundOrder = Order()

  /// The number of files in the queue of each source agent.
  private var counts: [ImportSourceAgent: Int] = [:]

  /// True when the queue holds no file.
  var isEmpty: Bool { levels.isEmpty }

  /// The number of files in the queue.
  var count: Int { levels.count }

  /// The number of files of one source agent in the queue.
  ///
  /// - Parameter agent: The source agent.
  /// - Returns: The number of files.
  func count(of agent: ImportSourceAgent) -> Int {
    counts[agent] ?? 0
  }

  /// The number of files at one level.
  ///
  /// - Parameter level: The level.
  /// - Returns: The number of files.
  func count(at level: ExternalSessionReadLevel) -> Int {
    levels.values.filter { $0 == level }.count
  }

  /// Adds a file. A file in the queue at level 2 moves to level 1 when `level` is level 1;
  /// each other file in the queue keeps its level.
  ///
  /// - Parameters:
  ///   - key: The file.
  ///   - modified: The modification date of the file.
  ///   - projectKey: The project key of the file, or `nil`.
  ///   - level: The level.
  mutating func enqueue(
    _ key: ExternalSessionFileKey, modified: Date, projectKey: String?,
    level: ExternalSessionReadLevel
  ) {
    switch levels[key] {
    case .folder:
      return
    case .background where level == .background:
      return
    case .background:
      break
    case nil:
      counts[key.agent, default: 0] += 1
    }
    levels[key] = level
    projectKeys[key] = projectKey
    place(Place(key: key, modified: modified), at: level)
  }

  /// Moves each file of a project folder from one level to the other.
  ///
  /// - Parameters:
  ///   - projectKey: The project key.
  ///   - agent: The source agent.
  ///   - level: The new level.
  ///   - modified: The modification date of each file, for its new place.
  mutating func move(
    projectKey: String, of agent: ImportSourceAgent, to level: ExternalSessionReadLevel,
    modified: (ExternalSessionFileKey) -> Date
  ) {
    let moving = levels.keys.filter { key in
      key.agent == agent && levels[key] != level && projectKeys[key] == projectKey
    }
    for key in moving {
      levels[key] = level
      place(Place(key: key, modified: modified(key)), at: level)
    }
  }

  /// Removes each file that a predicate selects.
  ///
  /// - Parameter isRemoved: The predicate: true for a file to remove.
  mutating func remove(where isRemoved: (ExternalSessionFileKey) -> Bool) {
    for key in levels.keys where isRemoved(key) {
      remove(key)
    }
  }

  /// Removes one file.
  ///
  /// - Parameter key: The file.
  mutating func remove(_ key: ExternalSessionFileKey) {
    guard levels.removeValue(forKey: key) != nil else { return }
    projectKeys[key] = nil
    counts[key.agent, default: 1] -= 1
  }

  /// Takes the next file: the newest file of level 1, else the newest file of level 2.
  ///
  /// - Returns: The file, or `nil` when the queue is empty.
  mutating func next() -> ExternalSessionFileKey? {
    while let place = folderOrder.popNewest() {
      if levels[place.key] == .folder { return take(place.key) }
    }
    while let place = backgroundOrder.popNewest() {
      if levels[place.key] == .background { return take(place.key) }
    }
    return nil
  }

  /// Adds a place to the order of a level.
  private mutating func place(_ place: Place, at level: ExternalSessionReadLevel) {
    switch level {
    case .folder: folderOrder.append(place)
    case .background: backgroundOrder.append(place)
    }
  }

  /// Removes a file that a worker takes, and gives it.
  private mutating func take(_ key: ExternalSessionFileKey) -> ExternalSessionFileKey {
    remove(key)
    return key
  }
}

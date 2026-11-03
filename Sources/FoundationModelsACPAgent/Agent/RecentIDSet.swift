/// A set of ids with a limit. At the limit, the oldest id leaves the set.
///
/// A long session holds a bounded number of ids.
struct RecentIDSet<ID: Hashable & Sendable>: Sendable {
  /// The most ids that the set keeps.
  let limit: Int

  /// The ids, for the lookup.
  private var ids: Set<ID> = []

  /// The ids in the order that they came, for the removal of the oldest.
  private var order: [ID] = []

  /// Makes an empty set.
  ///
  /// - Parameter limit: The most ids that the set keeps.
  init(limit: Int) {
    self.limit = limit
  }

  /// Whether the id is in the set.
  ///
  /// - Parameter id: The id.
  /// - Returns: `true` when the set holds the id.
  func contains(_ id: ID) -> Bool {
    ids.contains(id)
  }

  /// Adds an id. At the limit, the oldest id leaves the set.
  ///
  /// - Parameter id: The id.
  mutating func insert(_ id: ID) {
    guard ids.insert(id).inserted else {
      return
    }
    order.append(id)
    if order.count > limit {
      ids.remove(order.removeFirst())
    }
  }
}

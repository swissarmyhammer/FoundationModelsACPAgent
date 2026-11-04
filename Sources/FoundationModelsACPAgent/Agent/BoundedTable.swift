/// A table of values keyed by text that keeps the newest entries up to a limit. At the limit,
/// the oldest entry leaves. The table is a value type, so its owner guards it.
struct BoundedTable<Value: Sendable>: Sendable {
  /// The most entries that the table keeps.
  private let limit: Int

  /// The values by key.
  private var values: [String: Value] = [:]

  /// The keys in the order that they came, for the removal of the oldest.
  private var order: [String] = []

  /// Makes an empty table.
  ///
  /// - Parameter limit: The most entries that the table keeps.
  init(limit: Int) {
    self.limit = limit
  }

  /// The value for a key, or `nil`.
  subscript(key: String) -> Value? { values[key] }

  /// Stores a value. A key that the table holds keeps its place. At the limit, the oldest entry
  /// leaves.
  ///
  /// - Parameters:
  ///   - value: The value.
  ///   - key: The key.
  mutating func store(_ value: Value, for key: String) {
    if values.updateValue(value, forKey: key) == nil {
      order.append(key)
    }
    if order.count > limit {
      values.removeValue(forKey: order.removeFirst())
    }
  }

  /// Removes the value of a key.
  ///
  /// - Parameter key: The key.
  /// - Returns: The value, or `nil` when the table held none.
  mutating func remove(_ key: String) -> Value? {
    guard let value = values.removeValue(forKey: key) else {
      return nil
    }
    order.removeAll { $0 == key }
    return value
  }
}

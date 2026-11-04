import Testing

@testable import FoundationModelsACPAgent

/// ``BoundedTable`` keeps the newest entries up to a limit, keyed by text.
@Suite struct BoundedTableTests {
  /// The limit of the table in each test.
  private static let limit = 2

  @Test("a table at its limit drops the oldest entry on the next store")
  func theOldestEntryLeavesAtTheLimit() {
    var table = BoundedTable<Int>(limit: Self.limit)

    table.store(1, for: "a")
    table.store(2, for: "b")
    table.store(3, for: "c")

    #expect(table["a"] == nil)
    #expect(table["b"] == 2)
    #expect(table["c"] == 3)
  }

  @Test("a store under a known key replaces the value and keeps the place")
  func aKnownKeyReplacesTheValue() {
    var table = BoundedTable<Int>(limit: Self.limit)

    table.store(1, for: "a")
    table.store(2, for: "b")
    table.store(9, for: "a")
    table.store(3, for: "c")

    #expect(table["a"] == nil)
    #expect(table["b"] == 2)
  }

  @Test("remove returns the value and frees its place")
  func removeFreesThePlace() {
    var table = BoundedTable<Int>(limit: Self.limit)
    table.store(1, for: "a")
    table.store(2, for: "b")

    let removed = table.remove("a")
    table.store(3, for: "c")

    #expect(removed == 1)
    #expect(table["b"] == 2)
    #expect(table["c"] == 3)
  }

  @Test("remove of an unknown key returns nothing")
  func removeOfAnUnknownKeyReturnsNothing() {
    var table = BoundedTable<Int>(limit: Self.limit)
    table.store(1, for: "b")

    #expect(table.remove("a") == nil)
    #expect(table["b"] == 1)
  }
}

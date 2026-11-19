import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// The date index of the transcript search keeps its entries newest first after each change:
/// a small change with a binary search for each entry, and a large change in one pass
/// (^w0dheny).
@Suite struct TranscriptSearchDateIndexTests {
  // MARK: - Constants

  /// The number of entries of a small change: under the size of a large change.
  private static let smallCount = 8

  /// The number of entries of a large change: over the size of a large change.
  private static let largeCount = 400

  /// The number of different dates of the entries, so that some entries share a date.
  private static let dateCount = 7

  /// The number of sessions of the entries.
  private static let sessionCount = 5

  /// The period of the entries with no date.
  private static let noDatePeriod = 11

  /// The date of the first day of the entries.
  private static let firstDate = Date(timeIntervalSince1970: 1_775_044_800)

  /// The number of seconds of one hour.
  private static let secondsOfAnHour: TimeInterval = 3_600

  // MARK: - Fixtures

  /// An entry of the tests. The entries share dates and sessions, and some have no date.
  ///
  /// - Parameter number: The number of the entry.
  /// - Returns: The entry.
  private static func entry(_ number: Int) -> TranscriptSearchDateIndex.Entry {
    let date =
      number.isMultiple(of: noDatePeriod)
      ? nil
      : firstDate.addingTimeInterval(Double(number % dateCount) * secondsOfAnHour)
    return TranscriptSearchDateIndex.Entry(
      sessionId: SessionId(rawValue: "session-\(number % sessionCount)"), position: number,
      ordinal: number, kind: .agent, date: date)
  }

  /// The entries of a range of numbers.
  ///
  /// - Parameter numbers: The numbers.
  /// - Returns: The entries, in the order of the numbers.
  private static func entries(_ numbers: Range<Int>) -> [TranscriptSearchDateIndex.Entry] {
    numbers.map(entry)
  }

  // MARK: - Tests

  /// A large change gives the entries in the order of a sort.
  @Test func aLargeChangeGivesTheSortedOrder() {
    var index = TranscriptSearchDateIndex()

    index.replace([], with: Self.entries(0..<Self.largeCount))

    #expect(index.entries == TranscriptSearchDateIndex.sorted(Self.entries(0..<Self.largeCount)))
  }

  /// A small change removes its entries and inserts its new entries at their sorted places.
  @Test func aSmallChangeKeepsTheSortedOrder() {
    var index = TranscriptSearchDateIndex()
    index.replace([], with: Self.entries(0..<Self.largeCount))

    index.replace(
      Self.entries(0..<Self.smallCount),
      with: Self.entries(Self.largeCount..<(Self.largeCount + Self.smallCount)))

    #expect(
      index.entries
        == TranscriptSearchDateIndex.sorted(
          Self.entries(Self.smallCount..<(Self.largeCount + Self.smallCount))))
  }

  /// A large change that removes entries and inserts others keeps the other entries in order.
  @Test func aLargeChangeWithRemovalsKeepsTheSortedOrder() {
    var index = TranscriptSearchDateIndex()
    index.replace([], with: Self.entries(0..<Self.largeCount))

    index.replace(
      Self.entries(0..<Self.largeCount / 2),
      with: Self.entries(Self.largeCount..<(Self.largeCount * 2)))

    #expect(
      index.entries
        == TranscriptSearchDateIndex.sorted(
          Self.entries((Self.largeCount / 2)..<(Self.largeCount * 2))))
  }
}

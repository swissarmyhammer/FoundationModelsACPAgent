import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// A close of many sessions visits a session before the sessions nested in it. The session that
/// owns the surface stops the agent runs first, so a nested session never closes while its run
/// works. A nested session that closed first would end its run as cancelled and send the result
/// to the caller, and the recording would hold that result for the next start.
struct ClosingOrderTests {
  /// The number of sessions in the chain. It is large, so a visit in a chance order does not
  /// give the expected order by luck.
  private static let chainLength = 12

  /// A chain of sessions: each one is nested in the one before it.
  private static let chain = (0..<chainLength).map { SessionId(rawValue: "session-\($0)") }

  /// The parent of each nested session of the chain.
  private static let parents: [SessionId: SessionId] = Dictionary(
    uniqueKeysWithValues: zip(chain.dropFirst(), chain).map { ($0, $1) })

  /// The session that is nested the deepest comes first in the input. The order puts it last.
  @Test
  func aParentComesBeforeTheSessionsNestedInIt() {
    let order = RoutedACPAgent.parentsFirst(Self.chain.reversed(), parents: Self.parents)

    #expect(order == Self.chain)
  }

  /// A session with no parent in the table comes before a nested one, whatever the ids.
  @Test
  func aSessionWithNoParentComesFirst() {
    let nested = SessionId(rawValue: "a-nested")
    let root = SessionId(rawValue: "z-root")

    let order = RoutedACPAgent.parentsFirst([nested, root], parents: [nested: root])

    #expect(order == [root, nested])
  }

  /// A cycle in the parent links ends the walk. It never loops without end.
  @Test
  func aCycleOfParentsStillGivesEachSessionOnce() {
    let first = SessionId(rawValue: "first")
    let second = SessionId(rawValue: "second")

    let order = RoutedACPAgent.parentsFirst([second, first], parents: [first: second, second: first])

    #expect(Set(order) == [first, second] && order.count == 2)
  }
}

import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// The owner of a nested session comes from the parent links of the one
/// ``SessionTree`` that the table reads. The table keeps no second copy of
/// the links, so the two cannot differ.
struct ConnectionTableTreeTests {
  /// The session that has the owner record.
  private static let parent = SessionId(rawValue: "parent")

  /// A session that is nested in ``parent`` in the tree.
  private static let child = SessionId(rawValue: "child")

  /// A session that is in no tree link.
  private static let stranger = SessionId(rawValue: "stranger")

  /// The connection that starts ``parent``.
  private static let starter = ConnectionId(rawValue: "starter")

  /// The connection that takes ``parent`` later. The direct connection is
  /// a `userDevice`, so the rule of a take lets it take a session.
  private static let taker = ConnectionId.direct

  /// Makes a table over a tree where ``child`` is linked under ``parent``
  /// and ``parent`` is started by ``starter``.
  private static func makeLinkedTable() throws -> ConnectionTable {
    let tree = SessionTree()
    try tree.link(child, toParent: parent)
    let table = ConnectionTable(tree: tree)
    table.recordStart(of: parent, by: starter)
    return table
  }

  /// A link made in the tree alone gives the child the owner of its
  /// parent: the table needs no record of its own.
  @Test
  func aChildLinkedInTheTreeHasTheOwnerOfItsParent() throws {
    let table = try Self.makeLinkedTable()

    #expect(table.owner(of: Self.child) == Self.starter)
  }

  /// A take of the parent changes the owner that the child reads, at the
  /// next read.
  @Test
  func aTakeOfTheParentReachesTheChildThroughTheTree() throws {
    let table = try Self.makeLinkedTable()

    _ = table.take(Self.parent, by: Self.taker)

    #expect(table.owner(of: Self.child) == Self.taker)
  }

  /// A removed link leaves the child with no inherited owner.
  @Test
  func aChildUnlinkedFromTheTreeHasNoOwner() throws {
    let table = try Self.makeLinkedTable()

    table.tree.remove(Self.child)

    #expect(table.owner(of: Self.child) == nil)
  }

  /// A session that is in no link has no inherited owner.
  @Test
  func aSessionThatIsInNoLinkHasNoOwner() throws {
    let table = try Self.makeLinkedTable()

    #expect(table.owner(of: Self.stranger) == nil)
  }
}

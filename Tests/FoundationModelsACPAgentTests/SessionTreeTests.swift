import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// The parent links of the sessions of one agent: one chain of three
/// sessions (a root, a child and a grandchild) follows the same rule at each
/// link, and a refused link leaves the tree as it was.
@Suite struct SessionTreeTests {
  /// The number of children that the concurrent test links at the same
  /// time.
  private static let concurrentChildCount = 64

  /// The root of the chain.
  private static let root = SessionId(rawValue: "root")

  /// The session whose parent is the root.
  private static let child = SessionId(rawValue: "child")

  /// The session whose parent is the child.
  private static let grandchild = SessionId(rawValue: "grandchild")

  /// Makes a tree that holds the chain root, child, grandchild.
  ///
  /// - Returns: The tree.
  /// - Throws: Whatever a link throws.
  private static func makeChain() throws -> SessionTree {
    let tree = SessionTree()
    try tree.link(child, toParent: root)
    try tree.link(grandchild, toParent: child)
    return tree
  }

  /// The ancestors of the last session of a chain run from the root down
  /// to its parent.
  @Test
  func ancestorsOfTheGrandchildStartWithTheRoot() throws {
    let tree = try Self.makeChain()

    #expect(tree.ancestors(of: Self.grandchild) == [Self.root, Self.child])
  }

  /// The same rule holds at the middle link: the ancestors of the child
  /// are the root only.
  @Test
  func ancestorsOfTheChildAreTheRootOnly() throws {
    let tree = try Self.makeChain()

    #expect(tree.ancestors(of: Self.child) == [Self.root])
  }

  /// A session with no parent has no ancestor.
  @Test
  func theRootHasNoAncestor() throws {
    let tree = try Self.makeChain()

    #expect(tree.ancestors(of: Self.root).isEmpty)
  }

  /// The children of a session are its direct children, in the order of
  /// the links.
  @Test
  func childrenAreTheDirectChildrenInLinkOrder() throws {
    let tree = try Self.makeChain()
    let sibling = SessionId(rawValue: "sibling")
    try tree.link(sibling, toParent: Self.root)

    #expect(tree.children(of: Self.root) == [Self.child, sibling])
  }

  /// A session that is its own parent is refused.
  @Test
  func aSessionIsRefusedAsItsOwnParent() {
    let tree = SessionTree()

    #expect(throws: SessionTreeError.selfParent(Self.root)) {
      try tree.link(Self.root, toParent: Self.root)
    }
  }

  /// A link that would make a ring is refused, at the last link of the
  /// chain.
  @Test
  func aLinkThatMakesACycleIsRefused() throws {
    let tree = try Self.makeChain()

    #expect(throws: SessionTreeError.cycle(session: Self.root, parent: Self.grandchild)) {
      try tree.link(Self.root, toParent: Self.grandchild)
    }
  }

  /// A session has one parent: a second link for it is refused, and the
  /// first parent stays.
  @Test
  func aSecondParentIsRefusedAndTheFirstParentStays() throws {
    let tree = try Self.makeChain()
    let other = SessionId(rawValue: "other")

    #expect(
      throws: SessionTreeError.secondParent(
        session: Self.child, existing: Self.root, requested: other)
    ) {
      try tree.link(Self.child, toParent: other)
    }
    #expect(tree.parent(of: Self.child) == Self.root)
  }

  /// A removed link leaves the session and its parent as they were before
  /// the link, so the id can be linked again by a later start.
  @Test
  func aRemovedLinkLeavesNoChildAndNoParent() throws {
    let tree = try Self.makeChain()

    tree.remove(Self.grandchild)

    #expect(tree.parent(of: Self.grandchild) == nil)
    #expect(tree.children(of: Self.child).isEmpty)
  }

  /// Many tasks link children of one root at the same time, and the tree
  /// holds each link once.
  @Test
  func concurrentLinksAreAllKept() async throws {
    let tree = SessionTree()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<Self.concurrentChildCount {
        group.addTask {
          try tree.link(SessionId(rawValue: "child-\(index)"), toParent: Self.root)
        }
      }
      try await group.waitForAll()
    }

    #expect(tree.children(of: Self.root).count == Self.concurrentChildCount)
  }
}

import FoundationModelsACP
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The hold of a hot resume keeps the live sends of a tree in one queue until the resume is done,
/// and the table gives the hold of a take to each session of the tree.
struct SessionResumeHoldTests {
  /// The root session of the tree.
  private static let root = SessionId(rawValue: "root")

  /// A session nested in ``root``.
  private static let child = SessionId(rawValue: "child")

  /// The connection that owns ``root`` first.
  private static let starter = ConnectionId(rawValue: "starter")

  /// The connection that takes ``root``. The direct connection is a `userDevice`, so the rule of
  /// a take lets it take the session.
  private static let taker = ConnectionId.direct

  /// The labels of the sends of a test, in submit order.
  private static let labels = ["first", "second", "third"]

  /// The sends that ran, in the order that they ran.
  private final class SentLog: Sendable {
    /// The labels of the sends that ran.
    private let sent = Mutex<[String]>([])

    /// The labels, in the order that the sends ran.
    var labels: [String] {
      sent.withLock { $0 }
    }

    /// A send that adds its label to the log.
    ///
    /// - Parameter label: The label of the send.
    /// - Returns: The send.
    func send(_ label: String) -> SessionResumeHold.Send {
      { self.sent.withLock { $0.append(label) } }
    }
  }

  /// Makes a table over a tree where ``child`` is nested in ``root``, which ``starter`` owns.
  ///
  /// - Returns: The table.
  /// - Throws: Whatever the link throws.
  private static func makeLinkedTable() throws -> ConnectionTable {
    let tree = SessionTree()
    try tree.link(child, toParent: root)
    let table = ConnectionTable(tree: tree)
    table.recordStart(of: root, by: starter)
    return table
  }

  /// Submits each label of ``labels`` to a hold.
  ///
  /// - Parameters:
  ///   - hold: The hold.
  ///   - log: The log of the sends.
  private static func submitEachLabel(to hold: SessionResumeHold, loggingTo log: SentLog) async {
    for label in labels {
      await hold.submit(log.send(label))
    }
  }

  // MARK: - The hold

  /// A submit to a hold that holds returns at once, and runs nothing.
  @Test func aHoldThatHoldsRunsNoSend() async {
    let hold = SessionResumeHold(rootSessionId: Self.root)
    let log = SentLog()

    await Self.submitEachLabel(to: hold, loggingTo: log)

    #expect(log.labels.isEmpty)
  }

  /// The release runs each kept send, in the order of the submits.
  @Test func theReleaseRunsTheKeptSendsInOrder() async {
    let hold = SessionResumeHold(rootSessionId: Self.root)
    let log = SentLog()
    await Self.submitEachLabel(to: hold, loggingTo: log)

    await hold.release()

    #expect(log.labels == Self.labels)
  }

  /// A send after the release runs at once.
  @Test func aSendAfterTheReleaseRunsAtOnce() async {
    let hold = SessionResumeHold(rootSessionId: Self.root)
    let log = SentLog()
    await hold.release()

    await Self.submitEachLabel(to: hold, loggingTo: log)

    #expect(log.labels == Self.labels)
  }

  /// A discard drops the kept sends: a release after it runs none of them.
  @Test func aDiscardDropsTheKeptSends() async {
    let hold = SessionResumeHold(rootSessionId: Self.root)
    let log = SentLog()
    await Self.submitEachLabel(to: hold, loggingTo: log)

    hold.discard()
    await hold.release()

    #expect(log.labels.isEmpty)
  }

  // MARK: - The table

  /// A nested session gets the hold of the take of its root.
  @Test func aNestedSessionGetsTheHoldOfTheTakeOfItsRoot() throws {
    let table = try Self.makeLinkedTable()
    let hold = SessionResumeHold(rootSessionId: Self.root)

    _ = table.take(Self.root, by: Self.taker, holding: hold)

    #expect(table.route(forSession: Self.child)?.hold === hold)
  }

  /// A later take of the root ends the hold of the earlier take. The owner takes the root again,
  /// because the rule of a take lets an owner take its own session.
  @Test func aLaterTakeEndsTheHoldOfTheEarlierTake() async throws {
    let table = try Self.makeLinkedTable()
    let hold = SessionResumeHold(rootSessionId: Self.root)
    let log = SentLog()
    _ = table.take(Self.root, by: Self.taker, holding: hold)
    await Self.submitEachLabel(to: hold, loggingTo: log)

    _ = table.take(Self.root, by: Self.taker)
    await hold.release()

    #expect(log.labels.isEmpty)
  }

  /// The close of the owner ends the hold of its take.
  @Test func theCloseOfTheOwnerEndsTheHoldOfItsTake() async throws {
    let table = try Self.makeLinkedTable()
    let hold = SessionResumeHold(rootSessionId: Self.root)
    let log = SentLog()
    _ = table.take(Self.root, by: Self.taker, holding: hold)
    await Self.submitEachLabel(to: hold, loggingTo: log)

    table.remove(Self.taker)
    await hold.release()

    #expect(log.labels.isEmpty)
  }

  /// The removal of a released hold leaves the session with no hold.
  @Test func theRemovalOfAReleasedHoldLeavesNoHold() throws {
    let table = try Self.makeLinkedTable()
    let hold = SessionResumeHold(rootSessionId: Self.root)
    _ = table.take(Self.root, by: Self.taker, holding: hold)

    table.removeHold(hold, of: Self.root)

    #expect(table.route(forSession: Self.child)?.hold == nil)
  }
}

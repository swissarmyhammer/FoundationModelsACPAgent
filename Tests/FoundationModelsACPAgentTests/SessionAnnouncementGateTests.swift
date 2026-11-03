import FoundationModelsACPAgentTestSupport
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The gate of the updates of one session: a closed gate holds each send in
/// order, and the open sends the held sends before any later send. A submit
/// returns after its own send ran.
@Suite(.timeLimit(.minutes(1))) struct SessionAnnouncementGateTests {
  /// The log of the sends that went out, in order.
  private final class Sent: Sendable {
    /// The numbers that went out.
    private let numbers = Mutex<[Int]>([])

    /// The numbers that went out, in order.
    var values: [Int] {
      numbers.withLock { $0 }
    }

    /// Makes the send of one number.
    ///
    /// - Parameter number: The number.
    /// - Returns: The send.
    func send(_ number: Int) -> @Sendable () async -> Void {
      { self.numbers.withLock { $0.append(number) } }
    }
  }

  /// Waits until a count of submits wait in the gate. A submit that waits is a submit that the
  /// gate kept, so no test depends on the order in which tasks start.
  ///
  /// - Parameters:
  ///   - gate: The gate.
  ///   - count: The number of kept sends.
  private static func waitForPending(in gate: SessionAnnouncementGate, count: Int) async {
    while gate.pendingCount < count {
      await Task.yield()
    }
  }

  /// Starts a submit in a task of its own, and waits until the gate kept it. A submit to a gate
  /// that is not open waits for its send, so the test cannot wait in the same task.
  ///
  /// - Parameters:
  ///   - send: The send.
  ///   - gate: The gate.
  ///   - kept: The number of kept sends that the gate has after this submit.
  /// - Returns: The task of the submit.
  private static func submitKept(
    _ send: @escaping SessionAnnouncementGate.Send, to gate: SessionAnnouncementGate, kept: Int
  ) async -> Task<Void, Never> {
    let task = Task { await gate.submit(send) }
    await waitForPending(in: gate, count: kept)
    return task
  }

  /// A closed gate sends nothing.
  @Test
  func aClosedGateSendsNothing() async {
    let gate = SessionAnnouncementGate(isOpen: false)
    let sent = Sent()

    let submit = await Self.submitKept(sent.send(1), to: gate, kept: 1)

    #expect(sent.values.isEmpty)
    await gate.open()
    await submit.value
  }

  /// The open sends each held send, in the order of the submits.
  @Test
  func theOpenSendsTheHeldSendsInOrder() async {
    let gate = SessionAnnouncementGate(isOpen: false)
    let sent = Sent()
    let first = await Self.submitKept(sent.send(1), to: gate, kept: 1)
    let second = await Self.submitKept(sent.send(2), to: gate, kept: 2)

    await gate.open()

    await first.value
    await second.value
    #expect(sent.values == [1, 2])
  }

  /// A send after the open goes out at once.
  @Test
  func aSendAfterTheOpenGoesOutAtOnce() async {
    let gate = SessionAnnouncementGate(isOpen: false)
    let sent = Sent()
    await gate.open()

    await gate.submit(sent.send(1))

    #expect(sent.values == [1])
  }

  /// A gate that starts open sends at once.
  @Test
  func aGateThatStartsOpenSendsAtOnce() async {
    let gate = SessionAnnouncementGate(isOpen: true)
    let sent = Sent()

    await gate.submit(sent.send(1))

    #expect(sent.values == [1])
  }

  /// A submit that comes while the open sends the held sends goes after them, and it returns
  /// only after its own send ran. A caller that waits for its send (the `sent` continuation of
  /// a slash command) must not resume before the update is out.
  @Test
  func aSubmitDuringTheFlushReturnsAfterItsOwnSendRan() async {
    let gate = SessionAnnouncementGate(isOpen: false)
    let sent = Sent()
    let flushStarted = WatchedValue(false)
    let releaseFirst = WatchedValue(false)
    let first = await Self.submitKept(
      {
        flushStarted.update { $0 = true }
        _ = try? await releaseFirst.wait(for: "the release of the first send") { $0 }
        await sent.send(1)()
      }, to: gate, kept: 1)
    let opening = Task { await gate.open() }
    _ = try? await flushStarted.wait(for: "the flush") { $0 }
    let sentWhenItReturned = WatchedValue<[Int]?>(nil)
    let late = Task {
      await gate.submit(sent.send(3))
      sentWhenItReturned.update { $0 = sent.values }
    }
    await Self.waitForPending(in: gate, count: 1)

    releaseFirst.update { $0 = true }

    await opening.value
    await first.value
    await late.value
    #expect(sentWhenItReturned.value == [1, 3])
  }

  /// An opened gate reads as open: the client knows the session.
  @Test
  func anOpenedGateIsOpen() async {
    let gate = SessionAnnouncementGate(isOpen: false)

    await gate.open()

    #expect(gate.isOpen)
  }

  // MARK: The bound

  /// A gate that never opens keeps a bounded number of sends. At the bound, the oldest send
  /// leaves, so the newest sends stay. The gate counts what it dropped.
  @Test
  func aGateThatNeverOpensKeepsTheNewestSendsOnly() async {
    let gate = SessionAnnouncementGate(isOpen: false, pendingLimit: 2)
    let sent = Sent()
    let first = await Self.submitKept(sent.send(1), to: gate, kept: 1)
    let second = await Self.submitKept(sent.send(2), to: gate, kept: 2)
    let third = Task { await gate.submit(sent.send(3)) }
    await first.value

    await gate.open()

    await second.value
    await third.value
    #expect(sent.values == [2, 3])
    #expect(gate.droppedSendCount == 1)
  }

  /// The end of a gate that never opened drops its kept sends and frees each submit that waits.
  /// A later submit sends nothing.
  @Test
  func aDiscardedGateDropsTheKeptSendsAndFreesTheWaitingSubmits() async {
    let gate = SessionAnnouncementGate(isOpen: false)
    let sent = Sent()
    let waiting = await Self.submitKept(sent.send(1), to: gate, kept: 1)

    gate.discard()

    await waiting.value
    #expect(gate.droppedSendCount == 1)
    await gate.submit(sent.send(2))
    #expect(sent.values.isEmpty)
    #expect(!gate.isOpen)
  }

  /// A gate that is open stays open at a discard: the client knows the session.
  @Test
  func aDiscardDoesNotCloseAnOpenGate() async {
    let gate = SessionAnnouncementGate(isOpen: true)
    let sent = Sent()

    gate.discard()
    await gate.submit(sent.send(1))

    #expect(sent.values == [1])
    #expect(gate.isOpen)
  }
}

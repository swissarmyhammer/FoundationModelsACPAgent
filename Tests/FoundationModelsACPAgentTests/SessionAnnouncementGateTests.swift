import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The gate of the updates of one session: a closed gate holds each send in
/// order, and the open sends the held sends before any later send.
@Suite struct SessionAnnouncementGateTests {
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

    /// A closed gate sends nothing.
    @Test
    func aClosedGateSendsNothing() async {
        let gate = SessionAnnouncementGate(isOpen: false)
        let sent = Sent()

        await gate.submit(sent.send(1))

        #expect(sent.values.isEmpty)
    }

    /// The open sends each held send, in the order of the submits.
    @Test
    func theOpenSendsTheHeldSendsInOrder() async {
        let gate = SessionAnnouncementGate(isOpen: false)
        let sent = Sent()
        await gate.submit(sent.send(1))
        await gate.submit(sent.send(2))

        await gate.open()

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

    /// A send that comes while the open sends the held sends goes after them.
    @Test
    func aSendDuringTheFlushGoesAfterTheHeldSends() async {
        let gate = SessionAnnouncementGate(isOpen: false)
        let sent = Sent()
        await gate.submit { [gate] in
            await sent.send(1)()
            await gate.submit(sent.send(3))
        }
        await gate.submit(sent.send(2))

        await gate.open()

        #expect(sent.values == [1, 2, 3])
    }

    /// An opened gate reads as open: the client knows the session.
    @Test
    func anOpenedGateIsOpen() async {
        let gate = SessionAnnouncementGate(isOpen: false)

        await gate.open()

        #expect(gate.isOpen)
    }
}

import FoundationModelsACP
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The final status of an `agents` call waits for the end of the child that
/// the call started. The join table of the parent session holds the status
/// back, and the end of the child gives it out.
@Suite struct AgentCallHoldsTests {
    /// The completion token of the `agents` call.
    private static let token = "01HELDAGENTSCALLTOKEN00002"

    /// The SDK tool call id that the table joins to the token.
    private static let callId = ToolCallId(rawValue: "sdk-call-held")

    /// The log of the updates that went through the sink.
    private final class Sent: Sendable {
        /// The updates, in order.
        private let log = Mutex<[SessionUpdate]>([])

        /// The updates that went through, in order.
        var updates: [SessionUpdate] {
            log.withLock { $0 }
        }

        /// The sink that records.
        var sink: SessionUpdateSink {
            { update in self.log.withLock { $0.append(update) } }
        }
    }

    /// A table that joined the token to the call, with the hold in force.
    ///
    /// - Returns: The table.
    private static func makeHeldTable() -> RunCallJoinTable {
        let table = RunCallJoinTable()
        table.record(toolCallID: callId.rawValue, for: token)
        table.holds.hold(token)
        return table
    }

    /// The update that gives `status` to the call.
    ///
    /// - Parameters:
    ///   - status: The status.
    ///   - id: The call. The default is the held call.
    /// - Returns: The update.
    private static func statusUpdate(
        _ status: ToolCallStatus, of id: ToolCallId = callId
    ) -> SessionUpdate {
        .toolCallUpdate(ToolCallUpdate(toolCallId: id, status: .value(status)))
    }

    /// A final status of a held call does not go through.
    @Test
    func aFinalStatusOfAHeldCallDoesNotGoThrough() async {
        let sent = Sent()
        let sink = Self.makeHeldTable().deferringFinalStatus(of: sent.sink)

        await sink(Self.statusUpdate(.completed))

        #expect(sent.updates.isEmpty)
    }

    /// The release gives the held status back.
    @Test
    func theReleaseGivesTheHeldStatusBack() async {
        let table = Self.makeHeldTable()
        let sink = table.deferringFinalStatus(of: Sent().sink)
        await sink(Self.statusUpdate(.failed))

        let released = table.holds.release(Self.token)

        #expect(released == [ToolCallUpdate(toolCallId: Self.callId, status: .value(.failed))])
    }

    /// A status that is not final goes through at once.
    @Test
    func aStatusThatIsNotFinalGoesThroughAtOnce() async {
        let sent = Sent()
        let sink = Self.makeHeldTable().deferringFinalStatus(of: sent.sink)

        await sink(Self.statusUpdate(.inProgress))

        #expect(sent.updates == [Self.statusUpdate(.inProgress)])
    }

    /// The content of an update with a final status goes through, and the
    /// status waits.
    @Test
    func theContentGoesThroughAndTheStatusWaits() async {
        let sent = Sent()
        let sink = Self.makeHeldTable().deferringFinalStatus(of: sent.sink)
        let content = PatchField<[ToolCallContent]>.value([])

        await sink(.toolCallUpdate(ToolCallUpdate(toolCallId: Self.callId, content: content, status: .value(.completed))))

        #expect(sent.updates == [.toolCallUpdate(ToolCallUpdate(toolCallId: Self.callId, content: content))])
    }

    /// A call of another run goes through, also with a final status.
    @Test
    func aCallOfAnotherRunGoesThrough() async {
        let sent = Sent()
        let sink = Self.makeHeldTable().deferringFinalStatus(of: sent.sink)
        let other = ToolCallId(rawValue: "sdk-call-other")

        await sink(Self.statusUpdate(.completed, of: other))

        #expect(sent.updates == [Self.statusUpdate(.completed, of: other)])
    }

    /// After the release, a final status goes through at once.
    @Test
    func afterTheReleaseAFinalStatusGoesThrough() async {
        let table = Self.makeHeldTable()
        let sent = Sent()
        let sink = table.deferringFinalStatus(of: sent.sink)
        _ = table.holds.release(Self.token)

        await sink(Self.statusUpdate(.completed))

        #expect(sent.updates == [Self.statusUpdate(.completed)])
    }

    /// A run that has no hold goes through.
    @Test
    func aRunWithNoHoldGoesThrough() async {
        let table = RunCallJoinTable()
        table.record(toolCallID: Self.callId.rawValue, for: Self.token)
        let sent = Sent()

        await table.deferringFinalStatus(of: sent.sink)(Self.statusUpdate(.completed))

        #expect(sent.updates == [Self.statusUpdate(.completed)])
    }

    /// Two tables of one chain share the holds, so a call of a nested run is
    /// held by the table of its own session.
    @Test
    func aNestedTableSharesTheHoldsOfItsParent() async {
        let parent = RunCallJoinTable()
        let nested = RunCallJoinTable(holds: parent.holds)
        nested.record(toolCallID: Self.callId.rawValue, for: Self.token)
        parent.holds.hold(Self.token)
        let sent = Sent()

        await nested.deferringFinalStatus(of: sent.sink)(Self.statusUpdate(.completed))

        #expect(sent.updates.isEmpty)
    }

    /// The projector of the session sends the kept status when the hold ends, in the order of its
    /// inbox: an update that came before the release stays before the status, and one that comes
    /// after the release goes after it.
    @Test
    func theProjectorSendsTheKeptStatusAtTheReleaseInItsOwnOrder() async {
        let table = Self.makeHeldTable()
        let sent = Sent()
        let projector = SessionProjector(
            sessionId: SessionId(rawValue: "held-session"), modelName: "model", send: sent.sink, relay: nil,
            runCallJoins: table)
        let before = Self.statusUpdate(.inProgress, of: ToolCallId(rawValue: "before"))
        let after = Self.statusUpdate(.inProgress, of: ToolCallId(rawValue: "after"))

        await projector.commandSink(before)
        await projector.commandSink(Self.statusUpdate(.completed))
        await projector.releaseHold(of: Self.token)
        await projector.commandSink(after)

        #expect(sent.updates == [before, Self.statusUpdate(.completed), after])
        await projector.stop()
    }

    /// The release of a run that held nothing gives nothing.
    @Test
    func theReleaseOfARunThatHeldNothingGivesNothing() {
        #expect(AgentCallHolds().release(Self.token).isEmpty)
    }
}

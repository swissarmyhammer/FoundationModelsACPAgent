import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Synchronization
import Testing
import ULID

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

    /// Records one update, as a send of another session does.
    ///
    /// - Parameter update: The update.
    func send(_ update: SessionUpdate) async {
      log.withLock { $0.append(update) }
    }
  }

  /// A table that joined the token to the call, with the hold in force.
  ///
  /// - Returns: The table.
  private static func makeHeldTable() -> RunCallJoinTable {
    let table = RunCallJoinTable()
    table.record(toolCallID: callId.rawValue, for: RunToken(token))
    table.holds.runObserved(token)
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

    await sink(
      .toolCallUpdate(
        ToolCallUpdate(toolCallId: Self.callId, content: content, status: .value(.completed))))

    #expect(
      sent.updates == [.toolCallUpdate(ToolCallUpdate(toolCallId: Self.callId, content: content))])
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
    table.record(toolCallID: Self.callId.rawValue, for: RunToken(Self.token))
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
    nested.record(toolCallID: Self.callId.rawValue, for: RunToken(Self.token))
    parent.holds.runObserved(Self.token)
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
      sessionId: SessionId(rawValue: "held-session"), modelName: "model", send: sent.sink,
      relay: nil,
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

  // MARK: The order of the hold and the end of the run

  /// The open record of the `agents` call, as the translator of the parent gets it.
  ///
  /// - Returns: The record.
  private static func openRecord() -> ToolInvocationRecord {
    ToolInvocationRecord(
      tool: agentsTool, op: agentsTool, correlationID: token, sessionID: ULID(),
      openedAt: Date(timeIntervalSince1970: 0))
  }

  /// The name of the tool whose calls start a child.
  private static let agentsTool = "agents"

  /// A table of a surface that holds the calls of the `agents` tool. The run lookup tells which
  /// runs the runner knows when a call returns.
  ///
  /// - Parameter adoptedRun: What the lookup does for the token of a call that returned.
  /// - Returns: The table.
  private static func makeSurfaceTable(
    adoptedRun: @escaping @Sendable (String, AgentCallHolds) async -> Void
  ) -> RunCallJoinTable {
    let table = RunCallJoinTable()
    let holds = table.holds
    holds.bind(toolName: agentsTool) { token in await adoptedRun(token, holds) }
    return table
  }

  /// A hold that comes after the end of the run is not placed. The end came first, so the
  /// final status of the call goes through and nothing waits for a release that never comes.
  @Test
  func aHoldRequestedAfterTheEndOfTheRunIsNotPlaced() async {
    let table = RunCallJoinTable()
    table.record(toolCallID: Self.callId.rawValue, for: RunToken(Self.token))
    _ = table.holds.release(Self.token)
    let sent = Sent()

    let isPlaced = table.holds.hold(Self.token)
    await table.deferringFinalStatus(of: sent.sink)(Self.statusUpdate(.completed))

    #expect(!isPlaced)
    #expect(sent.updates == [Self.statusUpdate(.completed)])
  }

  /// A hold that comes before the end of the run is placed, and the end releases it.
  @Test
  func aHoldRequestedBeforeTheEndOfTheRunKeepsTheStatusUntilTheEnd() async {
    let table = RunCallJoinTable()
    table.record(toolCallID: Self.callId.rawValue, for: RunToken(Self.token))
    table.holds.runObserved(Self.token)
    let sent = Sent()

    let isPlaced = table.holds.hold(Self.token)
    await table.deferringFinalStatus(of: sent.sink)(Self.statusUpdate(.completed))
    let released = table.holds.release(Self.token)

    #expect(isPlaced)
    #expect(sent.updates.isEmpty)
    #expect(released == [ToolCallUpdate(toolCallId: Self.callId, status: .value(.completed))])
  }

  /// The open record of an `agents` call places the hold. The call starts the hold, not the
  /// first event of the child.
  @Test
  func theOpenRecordOfAnAgentsCallPlacesTheHold() {
    let table = Self.makeSurfaceTable { _, _ in }

    table.record(Self.openRecord(), toolCallID: Self.callId.rawValue)

    #expect(table.holds.heldCount == 1)
  }

  /// The open record of another tool places no hold, and the close record of the `agents` call
  /// places none.
  @Test
  func theRecordOfAnotherToolOrAClosedRecordPlacesNoHold() {
    let table = Self.makeSurfaceTable { _, _ in }
    let other = ToolInvocationRecord(
      tool: "runCode", op: "run", correlationID: "OTHER", sessionID: ULID(),
      openedAt: Date(timeIntervalSince1970: 0))

    table.record(other, toolCallID: nil)
    table.record(
      Self.openRecord().closed(at: Date(timeIntervalSince1970: 1)), toolCallID: Self.callId.rawValue
    )

    #expect(table.holds.heldCount == 0)
  }

  /// A call that goes to the background returns before its run gave an event. The runner knows
  /// the run, so the final status of the call waits for the end of the child. The end gives it out.
  @Test
  func aCallThatReturnsBeforeTheFirstEventOfItsRunKeepsTheFinalStatus() async {
    let table = Self.makeSurfaceTable { token, holds in holds.runObserved(token) }
    let sent = Sent()
    table.record(Self.openRecord(), toolCallID: Self.callId.rawValue)

    await table.deferringFinalStatus(of: sent.sink)(Self.statusUpdate(.completed))
    let released = table.holds.release(Self.token)

    #expect(sent.updates.isEmpty)
    #expect(released == [ToolCallUpdate(toolCallId: Self.callId, status: .value(.completed))])
  }

  /// A call that returned and started no run has no child traffic to wait for. The runner knows
  /// no run for the token, so the final status goes through at once and nothing stays held.
  @Test
  func aCallThatReturnedWithNoRunReleasesItsFinalStatusAtOnce() async {
    let table = Self.makeSurfaceTable { _, _ in }
    let sent = Sent()
    table.record(Self.openRecord(), toolCallID: Self.callId.rawValue)

    await table.deferringFinalStatus(of: sent.sink)(Self.statusUpdate(.completed))

    #expect(sent.updates == [Self.statusUpdate(.completed)])
    #expect(table.holds.heldCount == 0)
  }

  /// A foreground call returns while the child still has updates to send. The final status
  /// waits, so the updates of the child go before it. This fails when the hold is removed:
  /// the final status would go out first.
  @Test
  func aForegroundCallThatReturnsBeforeTheChildEndsSendsTheFinalStatusAfterTheChild() async {
    let table = Self.makeSurfaceTable { token, holds in holds.runObserved(token) }
    let sent = Sent()
    let projector = SessionProjector(
      sessionId: SessionId(rawValue: "foreground-parent"), modelName: "model", send: sent.sink,
      relay: nil,
      runCallJoins: table)
    let lastOfTheChild = Self.statusUpdate(.inProgress, of: ToolCallId(rawValue: "child-last"))
    table.record(Self.openRecord(), toolCallID: Self.callId.rawValue)

    await projector.commandSink(Self.statusUpdate(.completed))
    await sent.send(lastOfTheChild)
    await projector.releaseHold(of: Self.token)

    #expect(sent.updates == [lastOfTheChild, Self.statusUpdate(.completed)])
    await projector.stop()
  }

  /// The end of the announcer gives the holds up: no hold stays after `releaseAll`.
  @Test
  func releaseAllEndsEachHold() {
    let holds = AgentCallHolds()
    holds.hold(Self.token)

    holds.releaseAll()

    #expect(holds.heldCount == 0)
  }
}

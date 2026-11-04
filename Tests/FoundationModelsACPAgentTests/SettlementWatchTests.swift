import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Synchronization
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The wait for the settlement of a run that the host completed. A resume ends a claimed
/// `start agent` call of a child that does not restore as `lost`. The completion goes through the
/// Router session and the projector, in tasks of their own. The resume must not go on before the
/// projector sent the final status of the call, else the status comes after the current
/// `state_update` of the resume (task ^pmn2p11).
@Suite struct SettlementWatchTests {
  /// The completion token of the run that the tests settle.
  private static let token = "settlement-token"

  /// The order in which the steps of a test happened.
  private final class Steps: Sendable {
    /// The names of the steps, in order.
    private let names = Mutex<[String]>([])

    /// The names of the steps, in order.
    var recorded: [String] {
      names.withLock { $0 }
    }

    /// Notes one step.
    ///
    /// - Parameter name: The name of the step.
    func note(_ name: String) {
      names.withLock { $0.append(name) }
    }
  }

  /// The `runSettled` event of the run of the tests.
  private static var settlement: SessionEvent {
    .runSettled(
      OperationEvent(
        tool: "agents", op: "start agent", correlationID: token, kind: .completed, detail: "",
        outcome: .lost))
  }

  /// Whether an update is an update of a tool call.
  private static func isToolCallUpdate(_ update: SessionUpdate) -> Bool {
    if case .toolCallUpdate = update {
      return true
    }
    return false
  }

  /// The wait for a settlement returns after the projector sent the update of the settlement.
  /// This fails when the projector tells the settlement before it sends the status, or when it
  /// does not tell it.
  @Test
  func theWaitReturnsAfterTheProjectorSentTheStatusOfTheSettlement() async {
    let sink = RecordingSink()
    let projector = SessionProjector(
      sessionId: SessionId(rawValue: syntheticSessionIdValue), modelName: syntheticModelName,
      send: sink.send, relay: nil, runCallJoins: RunCallJoinTable())
    let (outputs, input) = AsyncStream.makeStream(of: SessionOutput.self)
    let source = SessionProjector.Source(id: ULID.generate(), session: nil)
    await projector.attach(outputs, from: source)
    projector.settlements.expect(Self.token)

    input.yield(SessionOutput(origin: .system, event: Self.settlement))
    await projector.settlements.wait(for: Self.token)

    #expect(sink.updates.contains(where: Self.isToolCallUpdate))
    input.finish()
    await projector.stop(after: [source.id])
  }

  /// The completion of a run returns only after the settlement. The settlement comes from another
  /// task, after the post of the completion returned.
  @Test
  func theCompletionReturnsOnlyAfterTheSettlement() async {
    let watch = SettlementWatch()
    let steps = Steps()

    let completion = Task {
      let completed = await watch.completing(Self.token) {
        steps.note("posted")
        return true
      }
      steps.note("completed")
      return completed
    }
    await Self.waitForStep("posted", in: steps)
    steps.note("settled")
    watch.settled(Self.token)

    #expect(await completion.value)
    #expect(steps.recorded == ["posted", "settled", "completed"])
  }

  /// A completion that the session refused waits for nothing.
  @Test
  func aRefusedCompletionWaitsForNothing() async {
    let watch = SettlementWatch()

    let completed = await watch.completing(Self.token) { false }

    #expect(!completed)
  }

  /// The end of the projector frees a wait that no settlement will end.
  @Test
  func theEndOfTheWatchFreesAWaiter() async {
    let watch = SettlementWatch()
    let steps = Steps()
    let completion = Task {
      await watch.completing(Self.token) {
        steps.note("posted")
        return true
      }
    }
    await Self.waitForStep("posted", in: steps)

    watch.close()

    #expect(await completion.value)
  }

  /// Yields until a step is noted. The test then does not depend on the order in which tasks start.
  ///
  /// - Parameters:
  ///   - name: The name of the step.
  ///   - steps: The steps of the test.
  private static func waitForStep(_ name: String, in steps: Steps) async {
    while !steps.recorded.contains(name) {
      await Task.yield()
    }
  }
}

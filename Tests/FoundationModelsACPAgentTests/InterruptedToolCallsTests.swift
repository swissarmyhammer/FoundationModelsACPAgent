import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// ``InterruptedToolCalls`` keeps the final status of a tool call out of the sends of a session
/// after the orderly shutdown began. The status `paused` and every other update still go out.
@Suite struct InterruptedToolCallsTests {
  /// The id of the tool call of the tests.
  private static let callId = ToolCallId(rawValue: "call-1")

  /// An update of the call with `status`.
  ///
  /// - Parameter status: The status of the update.
  /// - Returns: The update.
  private static func update(_ status: ToolCallStatus) -> SessionUpdate {
    .toolCallUpdate(ToolCallUpdate(toolCallId: callId, status: .value(status)))
  }

  /// Sends `updates` through the filter, and returns what reached the sink.
  ///
  /// - Parameters:
  ///   - updates: The updates to send, in order.
  ///   - interruption: The filter.
  /// - Returns: The updates that the sink got.
  private static func sent(
    _ updates: [SessionUpdate], through interruption: InterruptedToolCalls
  ) async -> [SessionUpdate] {
    let recorder = SinkRecorder()
    let send = interruption.filtering { await recorder.append($0) }
    for update in updates {
      await send(update)
    }
    return await recorder.updates
  }

  /// Before the shutdown began, a final status goes out as it always did.
  @Test
  func aFinalStatusGoesOutBeforeTheShutdownBegan() async {
    let sent = await Self.sent([Self.update(.completed)], through: InterruptedToolCalls())

    #expect(sent == [Self.update(.completed)])
  }

  /// After the shutdown began, a final status of each kind goes nowhere.
  @Test(arguments: [ToolCallStatus.completed, .failed, .cancelled])
  func aFinalStatusGoesNowhereAfterTheShutdownBegan(status: ToolCallStatus) async {
    let interruption = InterruptedToolCalls()
    interruption.begin()

    let sent = await Self.sent([Self.update(status)], through: interruption)

    #expect(sent.isEmpty)
  }

  /// After the shutdown began, the pause and a status that is not final still go out, with the
  /// updates that are no tool call update.
  @Test
  func theStatusPausedGoesOutAfterTheShutdownBegan() async {
    let interruption = InterruptedToolCalls()
    interruption.begin()
    let idle = SessionUpdate.stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn)))
    let updates = [Self.update(.paused), Self.update(.inProgress), idle]

    let sent = await Self.sent(updates, through: interruption)

    #expect(sent == updates)
  }
}

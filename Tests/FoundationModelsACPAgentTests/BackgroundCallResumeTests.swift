import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A resume ends or joins again each call whose run was in the background when the agent stopped.
///
/// The retained history keeps such a call `in_progress` or `paused`, with
/// `_meta.sah.backgroundRun.completionToken`. The journal of the session tells what became of the
/// run. A run that completed gives its final status now. A run that is orphaned gets the `_lost`
/// terminal of Router later, and that terminal must land on the same call. A run that the journal
/// does not know is lost now. Thus no row spins for ever.
@Suite struct BackgroundCallResumeTests {
  // MARK: - Constants

  /// The completion token of the run.
  private static let runToken = "01M7GBDPDZWDQ2WNB76FH80VA5"

  /// The SDK tool-call id of the call.
  private static let sdkCallId = "call-background-resume-1"

  /// The tool of the run.
  private static let toolName = "runCode"

  /// The op of the run.
  private static let opName = "run code"

  /// The wire value of the `_lost` status.
  private static let lostWireValue = "_lost"

  // MARK: - Fixtures

  /// The history of a session that holds one call of a run in the background, with `status`.
  ///
  /// - Parameter status: The status of the call.
  /// - Returns: The updates of the history.
  private static func history(status: FoundationModelsACP.ToolCallStatus) -> [SessionUpdate] {
    var update = ToolCallUpdate(toolCallId: ToolCallId(rawValue: sdkCallId))
    update.name = .value(toolName)
    update.status = .value(status)
    update.meta = .value(BackgroundRunMeta.meta(completionToken: runToken))
    return [.toolCallUpdate(update)]
  }

  /// The journal statuses that hold one status for the run.
  ///
  /// - Parameter status: The status of the run.
  /// - Returns: The statuses.
  private static func statuses(_ status: RunStatus) -> [RunKey: RunStatus] {
    [RunKey(tool: toolName, correlationID: runToken): status]
  }

  /// The status that the merged history gives the call after the restores.
  ///
  /// - Parameters:
  ///   - history: The updates of the history.
  ///   - restores: The restores of the resume.
  /// - Returns: The merged status, or `nil`.
  private static func mergedStatus(
    of history: [SessionUpdate], after restores: [BackgroundCallRestore]
  ) -> FoundationModelsACP.ToolCallStatus? {
    var finished = history
    for case .finish(let update) in restores {
      finished.append(.toolCallUpdate(update))
    }
    return finished.clientStatus(ofToolCall: sdkCallId)
  }

  // MARK: - A run that completed

  /// A paused call whose run completed as `stopped` while the agent did not run ends `cancelled`
  /// on the same id.
  @Test func aCallWhoseRunStoppedEndsCancelledOnTheSameId() {
    let history = Self.history(status: .paused)
    let restores = BackgroundCallRestore.restores(
      of: history, statuses: Self.statuses(.completed(.stopped)), skipping: [])

    #expect(Self.mergedStatus(of: history, after: restores) == .cancelled)
  }

  /// The final status of a run that completed while the agent did not run tells so.
  @Test func theFinalStatusOfARunThatEndedWhileTheAgentWasDownCarriesTheNote() {
    let restores = BackgroundCallRestore.restores(
      of: Self.history(status: .inProgress), statuses: Self.statuses(.completed(.succeeded)),
      skipping: [])

    let updates = restores.compactMap { restore -> ToolCallUpdate? in
      guard case .finish(let update) = restore else { return nil }
      return update
    }
    #expect(updates.flatMap { texts(in: $0.content) } == [BackgroundCallRestore.endedWhileDownText])
  }

  // MARK: - A run that is orphaned

  /// A call whose run is orphaned joins its token to its id again, so the `_lost` terminal of
  /// Router goes on the same id.
  @Test func aCallWhoseRunIsOrphanedJoinsItsTokenAgain() {
    let restores = BackgroundCallRestore.restores(
      of: Self.history(status: .paused), statuses: Self.statuses(.orphaned), skipping: [])

    #expect(
      restores == [.rejoin(token: Self.runToken, call: ToolCallId(rawValue: Self.sdkCallId))])
  }

  /// The updates that the `_lost` terminal of an orphaned run sends after the resume joined the
  /// token of the run to its call again.
  ///
  /// - Returns: The sent updates.
  private static func lostTerminalUpdatesAfterTheRejoin() async -> [SessionUpdate] {
    let (execution, recorder) = makeSinkedExecution()
    execution.runCallJoins.record(toolCallID: sdkCallId, for: RunToken(runToken))
    await execution.drive(
      events: makeEventStream([
        .runSettled(
          OperationEvent(
            tool: toolName, op: opName, correlationID: runToken, kind: .completed, detail: "",
            outcome: .lost))
      ]))
    return await recorder.updates
  }

  /// The `_lost` terminal of an orphaned run that joined again goes on the SDK id.
  @Test func theLostTerminalOfARejoinedRunLandsOnTheSdkId() async throws {
    let updates = await Self.lostTerminalUpdatesAfterTheRejoin()

    #expect(try updates.wireStatuses(ofToolCall: Self.sdkCallId) == [Self.lostWireValue])
  }

  /// The `_lost` terminal of an orphaned run that joined again opens no row keyed on the token.
  @Test func theLostTerminalOfARejoinedRunOpensNoNewRow() async {
    let updates = await Self.lostTerminalUpdatesAfterTheRejoin()

    #expect(toolCallUpdates(in: updates).allSatisfy { $0.toolCallId.rawValue == Self.sdkCallId })
  }

  // MARK: - A run that the journal does not know

  /// A call whose run the journal does not know is lost at once.
  @Test func aCallWhoseRunTheJournalDoesNotKnowIsLost() {
    let history = Self.history(status: .inProgress)
    let restores = BackgroundCallRestore.restores(of: history, statuses: [:], skipping: [])

    #expect(
      Self.mergedStatus(of: history, after: restores) == .unknown(Self.lostWireValue))
  }

  // MARK: - The calls that the resume leaves

  /// A call of an agent run that the resume restores gets nothing: the restore of the child
  /// drives it.
  @Test func aCallOfARestoredAgentRunGetsNothing() {
    let restores = BackgroundCallRestore.restores(
      of: Self.history(status: .paused), statuses: Self.statuses(.orphaned),
      skipping: [Self.runToken])

    #expect(restores.isEmpty)
  }

  /// A call with a final status gets nothing.
  @Test func aCallWithAFinalStatusGetsNothing() {
    let restores = BackgroundCallRestore.restores(
      of: Self.history(status: .completed), statuses: [:], skipping: [])

    #expect(restores.isEmpty)
  }
}

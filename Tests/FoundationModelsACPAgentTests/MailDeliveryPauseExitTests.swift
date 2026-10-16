import FoundationModelsACP
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent
import struct FoundationModelsRouter.MailDeliveryPause

/// The end of a headless `run` whose session paused its mail delivery (task
/// ^t03jd5h): the run does not report done. It writes the reason on stderr,
/// and it exits ``AgentExitCode/mailDeliveryPaused`` (6).
@Suite struct MailDeliveryPauseExitTests {
    /// The notice of a pause that holds two results at the limit `0`.
    private static let notice = HeldMailNotice(heldCount: 2, limit: 0)

    /// A run whose own prompt ended `end_turn` after a pause exits 6, and its
    /// stderr gets one line with the reason. stdout gets nothing more.
    @Test func aRunWithAPauseExitsSixAndWritesTheReasonOnStandardError() {
        let result = RunPromptResult(stopReason: .endTurn, mailPause: Self.notice)

        let code = AgentExitCode(prompt: result)
        let lines = AcpAgentCommand.Run.standardErrorLines(for: result)

        #expect(code == .mailDeliveryPaused)
        #expect(code.rawValue == 6)
        #expect(lines == [Self.notice.standardErrorLine])
        #expect(lines.first?.contains("held 2 run results") == true)
        #expect(lines.first?.contains("A headless run cannot send the next message") == true)
    }

    /// A run with no pause keeps the exit code of its stop reason, and
    /// writes no reason line.
    @Test func aRunWithNoPauseWritesNoReasonLine() {
        let result = RunPromptResult(stopReason: .endTurn)

        #expect(AgentExitCode(prompt: result) == .success)
        #expect(AcpAgentCommand.Run.standardErrorLines(for: result).isEmpty)
    }

    /// The CLI reads the update that the agent sends: the kinds are the same
    /// text, and the notice gets the counts of the report.
    @Test func theNoticeReadsTheUpdateThatTheAgentSends() {
        let event = OperationEvent(
            tool: "shell", op: "execute", correlationID: "run-1", kind: .completed, detail: "")
        let update = MailDeliveryPauseReport.update(for: MailDeliveryPause(limit: 0, heldMail: [event]))

        #expect(HeldMailNotice.updateKind == MailDeliveryPauseReport.updateKind)
        #expect(HeldMailNotice(update) == HeldMailNotice(heldCount: 1, limit: 0))
    }
}

import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// The wire report of the Router compactions of one session, from the
/// compaction events that the ``SessionProjector`` reads.
///
/// A compaction changes only the model context. The ACP history keeps each
/// message with its id, and the compaction shows as one more entry: an
/// `compaction_update`, keyed by one `compactionId` for each
/// compaction. The first update fixes the position of the entry, and each
/// later update with the same id changes it. A completed compaction also
/// sends a `usage_update` with the new context use.
///
/// Each update goes through ``send``, the history sink of the session. Thus
/// the retained history (`session-history.json`) keeps the compaction entry,
/// and a `session/resume` replays it with its final status and summary.
///
/// Router gives the summary whole, never in parts. Thus the summary goes on
/// the completed update, and no `compaction_summary_chunk` goes out.
struct CompactionReporter: Sendable {
    /// The sink of the updates: the history sink of the session.
    let send: SessionUpdateSink

    /// The reason a compaction left the context as it was, in words a user
    /// reads.
    ///
    /// - Parameter shortfall: The reason Router gave.
    /// - Returns: One sentence.
    static func shortfallReason(_ shortfall: CompactionShortfall) -> String {
        switch shortfall {
        case .targetLeavesNoRoomForSummary(let allowed):
            return "the fold target leaves no room for a summary (\(allowed) tokens)."
        case .inputFillsSummarizerWindow(let input, let window):
            return
                "the text to summarize (\(input) tokens) does not fit the window of any summarizer (\(window) tokens)."
        case .summaryDidNotShrinkContext(let snapshot):
            return "the summary did not make the context smaller (\(snapshot) tokens), so it was discarded."
        @unknown default:
            return "\(shortfall)."
        }
    }

    /// Reports the start of a compaction: the `in_progress` update, keyed by
    /// the id in the event. The id is the string form of the `SignalID` of
    /// the compaction signal, for a requested compaction (`/compact`, a
    /// library caller, a tool) and for an automatic one. The result or the
    /// failure of the same compaction carries the same id, so each compaction
    /// has one id (`mailbox.md`, section 3, work item 2).
    ///
    /// - Parameter start: The start that Router reported.
    func reportStart(_ start: CompactionStart) async {
        await send(
            .compactionUpdate(CompactionUpdate(compactionId: CompactionId(rawValue: start.id), status: .inProgress)))
    }

    /// Reports the end of a compaction that gave `result`: the terminal update
    /// of the entry that ``reportStart(_:)`` opened.
    ///
    /// A result with a shortfall left the context as it was: the update is
    /// `failed`, and the error says that the session was not compacted, why,
    /// and its tokens (``shortfallText(of:)``). Each other result is
    /// `completed`, with the summary when Router wrote one and the report of
    /// the fold (``reportText(of:)``), and then the `usage_update` with the
    /// new context use. The entry carries each fact that the text of
    /// `/compact` gave before the compaction was a signal.
    ///
    /// - Parameter result: The result of the compaction.
    func reportCompaction(_ result: CompactionResult) async {
        let compactionId = CompactionId(rawValue: result.id)
        if result.shortfall != nil {
            await reportFailure(of: compactionId, reason: Self.shortfallText(of: result))
            return
        }
        await send(
            .compactionUpdate(
                CompactionUpdate(
                    compactionId: compactionId, status: .completed, summary: Self.summaryPatch(of: result))))
        // The estimates of the compaction are the only sizes it gives. The
        // size before the compaction stands in for the context size, so the
        // visible effect is that the meter drops to the new use.
        await send(
            .usageUpdate(
                UsageUpdate(size: max(result.tokensBefore, result.tokensAfter), used: result.tokensAfter)))
    }

    /// Reports a compaction that did not complete: `cancelled` for a cancel,
    /// and `failed` with the error text that Router gave for each other
    /// failure. The context did not change, thus no `usage_update` goes
    /// out.
    ///
    /// - Parameter failure: The failure that Router reported.
    func reportFailure(_ failure: CompactionFailure) async {
        let compactionId = CompactionId(rawValue: failure.id)
        switch failure.outcome {
        case .cancelled:
            await reportCancel(of: compactionId)
        case .failed(let reason):
            await reportFailure(of: compactionId, reason: Self.failureText(reason))
        }
    }

    /// The text of the summarizer-model line of a fold that wrote no
    /// summary.
    static let noSummarizerModel = "none (no model wrote a summary)"

    /// The report of a fold that changed the context: the token counts
    /// before and after, and the summarizer model.
    ///
    /// - Parameter result: The result of the fold.
    /// - Returns: The report.
    static func reportText(of result: CompactionResult) -> String {
        let model = result.summarizerModel ?? noSummarizerModel
        return """
            Compacted the session.
            tokens before: \(result.tokensBefore)
            tokens after: \(result.tokensAfter)
            summarizer model: \(model)
            """
    }

    /// The error text of a fold that left the context as it was: the
    /// shortfall reason and the tokens of the context.
    ///
    /// - Parameter result: The result of the fold, with its shortfall.
    /// - Returns: The text.
    static func shortfallText(of result: CompactionResult) -> String {
        let reason = result.shortfall.map(shortfallReason) ?? ""
        return """
            The session was not compacted: \(reason)
            tokens: \(result.tokensBefore)
            """
    }

    /// The error text of a compaction that failed.
    ///
    /// - Parameter error: The error text that Router gave.
    /// - Returns: The text.
    static func failureText(_ error: String) -> String {
        "Compaction failed: \(error)"
    }

    /// Reports a compaction that a cancel stopped: the `cancelled` update,
    /// with no error.
    ///
    /// - Parameter compactionId: The id of the compaction.
    private func reportCancel(of compactionId: CompactionId) async {
        await send(.compactionUpdate(CompactionUpdate(compactionId: compactionId, status: .cancelled)))
    }

    /// Reports a compaction that failed: the `failed` update with the reason.
    ///
    /// - Parameters:
    ///   - compactionId: The id of the compaction.
    ///   - reason: Why the compaction failed, in words a user reads.
    private func reportFailure(of compactionId: CompactionId, reason: String) async {
        await send(
            .compactionUpdate(
                CompactionUpdate(compactionId: compactionId, status: .failed, error: .value(reason))))
    }

    /// The summary patch of a completed compaction: the summary as the first
    /// text block when Router wrote one, and then the report of the fold
    /// (``reportText(of:)``) as the last text block.
    ///
    /// - Parameter result: The result of the compaction.
    /// - Returns: The patch.
    private static func summaryPatch(of result: CompactionResult) -> PatchField<[ContentBlock]> {
        let summary = result.summary.map { [ContentBlock.text(TextContent(text: $0))] } ?? []
        return .value(summary + [.text(TextContent(text: reportText(of: result)))])
    }
}

import Foundation
import FoundationModelsACP
import FoundationModelsRouter
import Logging

/// The wire report of the Router compactions of one session (plan.md §8.5).
///
/// A compaction changes only the model context. The ACP history keeps each
/// message with its id, and the compaction shows as one more entry: an
/// UNSTABLE `compaction_update`, keyed by one `compactionId` for each
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
    /// The session the compactions belong to, for the log.
    let sessionId: SessionId

    /// The sink of the updates: the history sink of the session.
    let send: SessionUpdateSink

    /// Makes the id of a compaction that the agent starts itself, such as a
    /// `/compact`. The agent sends `in_progress` before the compaction runs,
    /// and Router names its own id only in the result.
    ///
    /// - Returns: A new id, unique in the session.
    static func makeCompactionId() -> Unstable.CompactionId {
        Unstable.CompactionId(rawValue: ULID.generate().description)
    }

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

    /// Reports an automatic compaction: Router ran it inside an answer and
    /// gave only its result. Router reports no start, thus the first update
    /// of the entry is the terminal one, keyed by the id of the result.
    ///
    /// - Parameter result: The result of the compaction.
    func reportAutomaticCompaction(_ result: CompactionResult) async {
        await reportEnd(of: Unstable.CompactionId(rawValue: result.id), with: result)
    }

    /// Reports that a compaction started: the `in_progress` update.
    ///
    /// - Parameter compactionId: The id of the compaction.
    func reportStart(of compactionId: Unstable.CompactionId) async {
        await post(.compactionUpdate(Unstable.CompactionUpdate(compactionId: compactionId, status: .inProgress)))
    }

    /// Reports the end of a compaction that gave `result`.
    ///
    /// A result with a shortfall left the context as it was: the update is
    /// `failed`, and the error is the reason. Each other result is
    /// `completed`, with the summary when Router wrote one, and then the
    /// `usage_update` with the new context use.
    ///
    /// - Parameters:
    ///   - compactionId: The id of the compaction.
    ///   - result: The result of the compaction.
    func reportEnd(of compactionId: Unstable.CompactionId, with result: CompactionResult) async {
        if let shortfall = result.shortfall {
            await reportFailure(of: compactionId, reason: Self.shortfallReason(shortfall))
            return
        }
        await post(
            .compactionUpdate(
                Unstable.CompactionUpdate(
                    compactionId: compactionId, status: .completed, summary: Self.summaryPatch(of: result))))
        // The estimates of the compaction are the only sizes it gives. The
        // size before the compaction stands in for the context size, so the
        // visible effect is that the meter drops to the new use.
        await send(
            .usageUpdate(
                UsageUpdate(size: max(result.tokensBefore, result.tokensAfter), used: result.tokensAfter)))
    }

    /// Reports the end of a compaction that threw `error`: `cancelled` for
    /// a cancellation, and `failed` with the error for each other error.
    ///
    /// - Parameters:
    ///   - compactionId: The id of the compaction.
    ///   - error: The error the compaction threw.
    func reportEnd(of compactionId: Unstable.CompactionId, throwing error: any Error) async {
        guard error is CancellationError else {
            await reportFailure(of: compactionId, reason: String(describing: error))
            return
        }
        await post(.compactionUpdate(Unstable.CompactionUpdate(compactionId: compactionId, status: .cancelled)))
    }

    /// Reports a compaction that failed: the `failed` update with the reason.
    ///
    /// - Parameters:
    ///   - compactionId: The id of the compaction.
    ///   - reason: Why the compaction failed, in words a user reads.
    private func reportFailure(of compactionId: Unstable.CompactionId, reason: String) async {
        await post(
            .compactionUpdate(
                Unstable.CompactionUpdate(compactionId: compactionId, status: .failed, error: .value(reason))))
    }

    /// The summary patch of a completed compaction: the summary as one text
    /// block, or no change when Router wrote no summary.
    ///
    /// - Parameter result: The result of the compaction.
    /// - Returns: The patch.
    private static func summaryPatch(of result: CompactionResult) -> PatchField<[ContentBlock]> {
        guard let summary = result.summary else {
            return .unchanged
        }
        return .value([.text(TextContent(text: summary))])
    }

    /// Sends one UNSTABLE update as the stable session update that carries
    /// it.
    ///
    /// The payload holds only strings and ids, thus the encode does not
    /// fail. A failure is a defect: a debug build stops, and a release build
    /// logs it and sends nothing.
    ///
    /// - Parameter update: The unstable update.
    private func post(_ update: Unstable.SessionUpdate) async {
        let wire: SessionUpdate
        do {
            wire = try SessionUpdate(update)
        } catch {
            assertionFailure("A compaction update did not encode: \(error)")
            ACPAgentTelemetry.logger(.session).error(
                "A compaction update did not encode. The update is not sent.",
                metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
            return
        }
        await send(wire)
    }
}

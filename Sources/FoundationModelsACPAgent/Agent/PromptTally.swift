import FoundationModelsACP
import FoundationModelsRouter
import Logging

/// The counts of one prompt: the usage, the finish reason of its last
/// submission, the Router stops, the changed files, and whether it made
/// observable output.
///
/// The ``SessionProjector`` translates each event of the session, but it
/// counts an event for a prompt only when the origin of the event holds the
/// `MailID` of that prompt. The answers that the mail of a background run
/// starts belong to no prompt, so they change no count of a prompt. The
/// projector gives the tally of the prompt to the ``ACPEventTranslator``
/// before it translates an event of the prompt, and takes it back after.
struct PromptTally: Sendable {
    /// The prompt tokens summed across every `submissionEnded`. A
    /// tool loop feeds the whole render again at each generation call, so
    /// this sum is not the size of the context.
    var tokensIn = 0

    /// The completion tokens summed across every `submissionEnded`.
    var tokensOut = 0

    /// The fill of the last generation call, the peak fill and the context
    /// window, from the `generationCall` reports of the prompt (task
    /// ^1x5ksdv).
    var contextUsage = PromptContextUsage()

    /// The finish reason of the last submission of the prompt, or `nil`
    /// before the first `submissionEnded`.
    ///
    /// The end of the prompt reads it to report the honest stop reason of
    /// a prompt whose last submission did not end by itself (tasks ^bw9qt1z,
    /// ^k51h6bb and ^7fsfw7y): the text, the reasoning or the tool call of
    /// that generation is cut, so the prompt must not read as a normal
    /// `end_turn`.
    var lastFinishReason: FinishReason?

    /// The number of generate calls of the prompt that Router stopped: the
    /// repetition stops and the reasoning stops (task ^dcmsxpw).
    var routerStopCount = 0

    /// The number of Router stops of the prompt that a recovery followed.
    var routerRecoveryCount = 0

    /// The report of the last reasoning stop of the prompt, or `nil` when
    /// Router stopped no pass for its reasoning.
    var lastReasoningStop: ReasoningStop?

    /// The paths of the files that a `FileChangeSet` of the prompt recorded.
    ///
    /// Only a mutating files verb attaches a change set. A shell command that
    /// writes a file records no change, thus this set does not hold that
    /// file.
    var changedFilePaths: Set<String> = []

    /// The context fill of the last submission: the context that the session
    /// holds after it, over the window. `nan` means "no stamp": send no
    /// meter for the prompt. A `NaN` never goes on the wire.
    var contextFill = Double.nan

    /// Whether the prompt produced observable output: a text delta, a
    /// reasoning delta, a tool call or status, an invocation record,
    /// an attachment report, a display event of a tool, a relayed
    /// elicitation, or a run settlement (task ^pez780d).
    ///
    /// The progress of a run does not count (task ^jwx92y8): a text progress
    /// and a plan tell about a run, not about the generation of the model.
    ///
    /// The stall guard reads it beside a stall report as well: a prompt that
    /// already produced something is not waiting on a model that cannot
    /// generate (task ^s0bw5cv).
    var sawOutput = false

    /// Whether at least one `submissionEnded` usage report arrived
    /// (task ^pez780d).
    var sawUsageReport = false

    /// The number of distinct files that the files verbs of the prompt
    /// changed.
    var changedFileCount: Int { changedFilePaths.count }

    /// Whether the prompt generated nothing: no observable output, while
    /// at least one `submissionEnded` arrived and the summed output tokens
    /// are zero. The end of the prompt reads it to report the honest
    /// `_no_output` stop reason instead of a bare `end_turn`
    /// (the ACP `_` extension rule; task ^pez780d).
    var generatedNothing: Bool {
        !sawOutput && sawUsageReport && tokensOut == 0
    }

    /// The numbers behind a stop reason, as log metadata, for the record of a
    /// prompt that ended cut or empty.
    ///
    /// A `_truncated`, `_ended_in_reasoning`, `_repeated` or
    /// `_reasoning_limit` prompt says how the last submission stopped, and
    /// nothing more. The reader then cannot
    /// tell a model that reasoned too long in one round from a context that
    /// filled up. These numbers name the difference: the tokens that all the
    /// generation calls of the prompt fed and generated, summed, and from the
    /// call reports, the fill of the last call, the peak fill and the context
    /// window (``PromptContextUsage/metadata``).
    var usageMetadata: Logger.Metadata {
        var metadata: Logger.Metadata = [
            ACPAgentTelemetry.LogMetadataKey.tokensIn: "\(tokensIn)",
            ACPAgentTelemetry.LogMetadataKey.tokensOut: "\(tokensOut)",
        ]
        metadata.merge(contextUsage.metadata) { current, _ in current }
        return metadata
    }

    /// The metadata of the record of a cut prompt (task ^dcmsxpw): the
    /// ``usageMetadata``, the Router stops and the recoveries that ran, the
    /// number of changed files, and the reasoning tokens and the limit of
    /// the last reasoning stop.
    ///
    /// The Router writes its own stop records at the `notice` level, and a
    /// run that logs at `warning` or above does not keep them. So this one
    /// `error` record must name the cause by itself.
    var cutMetadata: Logger.Metadata {
        typealias Key = ACPAgentTelemetry.LogMetadataKey
        var metadata = usageMetadata
        metadata[Key.routerStops] = "\(routerStopCount)"
        metadata[Key.routerRecoveries] = "\(routerRecoveryCount)"
        metadata[Key.filesChanged] = "\(changedFileCount)"
        if let stop = lastReasoningStop {
            metadata[Key.reasoningTokens] = "\(stop.reasoningTokens)"
            metadata[Key.reasoningLimit] = "\(stop.limit.map(String.init) ?? "none")"
        }
        return metadata
    }

    /// Counts one generate call that Router stopped, and the recovery that
    /// follows it, for the record of a cut prompt (task ^dcmsxpw).
    ///
    /// - Parameter recovery: The number of the recovery that follows the
    ///   stop, or `nil` when no recovery was left.
    mutating func countRouterStop(recovery: Int?) {
        routerStopCount += 1
        if recovery != nil {
            routerRecoveryCount += 1
        }
    }

    /// Adds the usage of one ended submission. One event comes for each
    /// submission, not for each prompt. The LAST submission is the one that
    /// ends the prompt, so its finish reason wins over each earlier one.
    ///
    /// - Parameter end: The end of the submission.
    mutating func record(_ end: SubmissionEnd) {
        lastFinishReason = end.finishReason
        guard let usage = end.usage else { return }
        sawUsageReport = true
        tokensIn += usage.tokensIn
        tokensOut += usage.tokensOut
        contextFill = usage.contextFill
    }

    /// The one `usage_update` of the prompt (task ^1x5ksdv), or `nil` when
    /// no meter goes on the wire.
    ///
    /// `size` is the context window that the generation calls measured, and
    /// `used` is the fill of the last submission over that window: the
    /// tokens now in the context. The summed tokens of the prompt are not
    /// the context, because a tool loop feeds the whole render again at
    /// each call. A `nan` context fill means "no stamp", and a prompt with
    /// no call report has no window: then no meter goes on the wire.
    var usageUpdate: UsageUpdate? {
        guard let size = contextUsage.windowTokens, let used = contextUsage.tokens(atFill: contextFill) else {
            return nil
        }
        return UsageUpdate(size: size, used: used)
    }
}

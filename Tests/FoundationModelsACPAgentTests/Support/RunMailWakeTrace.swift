import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The trace of an answer that run mail starts after the prompt that
/// started the run returned (task ^3p03s3r).
///
/// The run that a prompt leaves in the background posts its mail later. The
/// Router keeps the tracing context of the poster with the mail, so the
/// submission of that answer is a child of a span of the prompt, and it
/// links to the span of each sender. These checks read the spans of one
/// traced run.
enum RunMailWakeTrace {
    /// Whether `span` is a Router submission that run mail alone started.
    ///
    /// - Parameter span: A span that ended.
    /// - Returns: `true` for a `FoundationModelsRouter.submission` span whose
    ///   `submission.cause` reads `mail`.
    static func isRunMailSubmission(_ span: FinishedInMemorySpan) -> Bool {
        span.operationName == RouterTelemetry.SpanName.submission
            && span.attributes.get(RouterTelemetry.AttributeKey.submissionCause)
                == .string(SubmissionStart.Cause.mail.rawValue)
    }

    /// Whether the span with the id `spanID` is `root` or a descendant of
    /// `root`: the walk goes up the parent ids of the spans that ended, and
    /// stops at a span that has no parent or that did not end.
    ///
    /// - Parameters:
    ///   - spanID: The id of the span that the walk starts at.
    ///   - root: The span that the walk looks for.
    ///   - spans: The spans that ended.
    /// - Returns: `true` when the walk reaches `root`.
    static func isSpan(
        _ spanID: String, inTheSubtreeOf root: FinishedInMemorySpan, among spans: [FinishedInMemorySpan]
    ) -> Bool {
        let parents = Dictionary(spans.map { ($0.spanID, $0.parentSpanID) }, uniquingKeysWith: { first, _ in first })
        let ancestors = sequence(first: spanID) { id in parents[id] ?? nil }
        return ancestors.prefix(spans.count + 1).contains(root.spanID)
    }

    /// Expects the submission that run mail started to be in the trace of
    /// the one prompt span of `spans`: it has the trace id of the prompt, it
    /// is no root span, its parent is in the subtree of the prompt span, and
    /// it links to at least one sender, each in that subtree.
    ///
    /// - Parameters:
    ///   - spans: The spans of the traced run.
    ///   - sourceLocation: The source location that each issue names.
    /// - Throws: When `spans` holds no prompt span, no run mail submission,
    ///   or a run mail submission with no parent.
    static func expectTheWakeIsInTheTraceOfThePrompt(
        among spans: [FinishedInMemorySpan], sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let prompt = try #require(
            spans.first { $0.operationName == ACPAgentTelemetry.SpanName.prompt }, sourceLocation: sourceLocation)
        let wake = try #require(spans.first(where: isRunMailSubmission), sourceLocation: sourceLocation)
        let parent = try #require(
            wake.parentSpanID, "the wake on run mail is a root span", sourceLocation: sourceLocation)
        #expect(wake.traceID == prompt.traceID, sourceLocation: sourceLocation)
        #expect(isSpan(parent, inTheSubtreeOf: prompt, among: spans), sourceLocation: sourceLocation)
        let senders = wake.links.compactMap { $0.context.inMemorySpanContext?.spanID }
        #expect(!senders.isEmpty, sourceLocation: sourceLocation)
        #expect(
            senders.allSatisfy { isSpan($0, inTheSubtreeOf: prompt, among: spans) }, "\(senders)",
            sourceLocation: sourceLocation)
    }
}

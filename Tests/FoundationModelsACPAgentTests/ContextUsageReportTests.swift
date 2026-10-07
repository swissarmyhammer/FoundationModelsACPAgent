import FoundationModelsACP
import FoundationModelsRouter
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The context usage that a prompt reports (task ^1x5ksdv): the fill of the
/// last generation call, the peak fill of the prompt and the context window,
/// in the record of a cut prompt and in the one `usage_update` of the prompt.
///
/// Before this task, the record gave the fill of the last submission only,
/// and the meter divided the summed tokens of all calls by that fill. A tool
/// loop feeds the whole render again at each call, so the sum is not the
/// context, and the derived window was wrong. The numbers below come from the
/// SWE-bench transcript of django__django-13964, where the window is 262144
/// tokens.
@Suite struct ContextUsageReportTests {
    // MARK: - Constants

    /// The context window of the session, in tokens.
    private static let windowTokens = 262_144

    /// The fed tokens of the call that filled the context most.
    private static let peakCallTokensIn = 120_000

    /// The generated tokens of the call that filled the context most.
    private static let peakCallTokensOut = 1_072

    /// The fed tokens of the last call of the prompt.
    private static let lastCallTokensIn = 50_193

    /// The generated tokens of the last call of the prompt.
    private static let lastCallTokensOut = 80

    /// The fed tokens of the prompt, summed over every call.
    private static let summedTokensIn = 1_233_016

    /// The generated tokens of the prompt, summed over every call.
    private static let summedTokensOut = 45_956

    // MARK: - Fixtures

    /// Makes the usage event of one generation call, with the fill that
    /// Router gives it: the fed and generated tokens over the window.
    ///
    /// - Parameters:
    ///   - tokensIn: The fed tokens of the call.
    ///   - tokensOut: The generated tokens of the call.
    /// - Returns: The event.
    private static func makeGenerationCall(tokensIn: Int, tokensOut: Int) -> SessionEvent {
        .generationCall(
            GenerationCallUsage(
                tokensIn: tokensIn, tokensOut: tokensOut, finishReason: .completed, entryKind: .toolCall,
                contextFill: Double(tokensIn + tokensOut) / Double(windowTokens)))
    }

    /// The two calls of the scripted prompt: first the call that filled the
    /// context most, then a smaller last call.
    private static var peakThenLastCall: [SessionEvent] {
        [
            makeGenerationCall(tokensIn: peakCallTokensIn, tokensOut: peakCallTokensOut),
            makeGenerationCall(tokensIn: lastCallTokensIn, tokensOut: lastCallTokensOut),
        ]
    }

    /// Makes the end of the one submission of the scripted prompt. Its usage
    /// sums the tokens of all calls, and its fill is the context that the
    /// last call left.
    ///
    /// - Parameter finishReason: Why the submission stopped.
    /// - Returns: The event.
    private static func makeSummedSubmissionEnd(finishReason: FinishReason) -> SessionEvent {
        makeSubmissionEnded(
            TokenUsage(
                tokensIn: summedTokensIn, tokensOut: summedTokensOut,
                contextFill: Double(lastCallTokensIn + lastCallTokensOut) / Double(windowTokens),
                finishReason: finishReason))
    }

    /// Drives a prompt that ends at the reasoning token limit, and returns
    /// the one `error` record of the cut prompt.
    ///
    /// - Parameter calls: The generation call events before the end.
    /// - Returns: The record of the cut prompt.
    private static func cutRecord(after calls: [SessionEvent]) async throws -> TelemetryCapture.LogRecord {
        let events = calls + [makeSummedSubmissionEnd(finishReason: .reasoningTokenLimit)]
        let records = try await TelemetryCapture.run(forbidding: []) { context in
            let (execution, _) = makeSinkedExecution()
            _ = await execution.drive(events: makeEventStream(events))
            return context.logRecords
        }
        let cut = records.filter { $0.level == .error }
        #expect(cut.count == 1)
        return try #require(cut.first)
    }

    /// Drives a prompt that ends by itself, and returns its usage updates.
    ///
    /// - Parameter calls: The generation call events before the end.
    /// - Returns: The usage updates the prompt sent, in order.
    private static func usageUpdates(after calls: [SessionEvent]) async -> [UsageUpdate] {
        let (execution, recorder) = makeSinkedExecution()
        _ = await execution.drive(
            events: makeEventStream(calls + [makeSummedSubmissionEnd(finishReason: .completed)]))
        return await recorder.updates.compactMap(usageReport(of:))
    }

    // MARK: - The record of a cut prompt

    /// The record gives the fill of the last generation call, not the fill
    /// of the call that filled the context most.
    @Test func theCutRecordGivesTheFillOfTheLastGenerationCall() async throws {
        let record = try await Self.cutRecord(after: Self.peakThenLastCall)

        #expect(record.metadata[ACPAgentTelemetry.LogMetadataKey.lastCallContextFill] == "0.192")
    }

    /// The record gives the peak fill of the prompt: the largest fill of
    /// all its generation calls.
    @Test func theCutRecordGivesThePeakFillOfThePrompt() async throws {
        let record = try await Self.cutRecord(after: Self.peakThenLastCall)

        #expect(record.metadata[ACPAgentTelemetry.LogMetadataKey.peakContextFill] == "0.462")
    }

    /// The record gives the context window that the generation calls
    /// measure: the context of one call divided by its fill.
    @Test func theCutRecordGivesTheContextWindowThatTheCallsMeasure() async throws {
        let record = try await Self.cutRecord(after: Self.peakThenLastCall)

        #expect(record.metadata[ACPAgentTelemetry.LogMetadataKey.contextTokens] == "\(Self.windowTokens)")
    }

    /// With no generation call report, the record does not know the fills
    /// or the window, and says so.
    @Test func theCutRecordSaysUnknownWhenNoGenerationCallWasReported() async throws {
        let record = try await Self.cutRecord(after: [])
        let keys = ACPAgentTelemetry.LogMetadataKey.self

        #expect(record.metadata[keys.lastCallContextFill] == "unknown")
        #expect(record.metadata[keys.peakContextFill] == "unknown")
        #expect(record.metadata[keys.contextTokens] == "unknown")
    }

    // MARK: - The usage update

    /// The `size` of the meter is the context window that the generation
    /// calls measure, not the summed tokens divided by a fill.
    @Test func theUsageUpdateSizeIsTheContextWindow() async throws {
        let usage = try #require(await Self.usageUpdates(after: Self.peakThenLastCall).first)

        #expect(usage.size == Self.windowTokens)
    }

    /// The `used` of the meter is the context that the prompt left, which is
    /// the fill of the last submission over the window, not the sum of the
    /// fed tokens of all calls.
    @Test func theUsageUpdateUsedIsTheContextThatThePromptLeft() async throws {
        let usage = try #require(await Self.usageUpdates(after: Self.peakThenLastCall).first)

        #expect(usage.used == Self.lastCallTokensIn + Self.lastCallTokensOut)
    }

    /// With no generation call report, the prompt does not know the window,
    /// so it sends no meter.
    @Test func aPromptWithNoGenerationCallReportSendsNoUsageUpdate() async {
        #expect(await Self.usageUpdates(after: []).isEmpty)
    }
}

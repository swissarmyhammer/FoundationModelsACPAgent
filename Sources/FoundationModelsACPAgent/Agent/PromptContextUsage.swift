import Foundation
import FoundationModelsRouter
import Logging

/// The context usage of one prompt, from the usage report of each generation
/// call (task ^1x5ksdv).
///
/// The usage of a `submissionEnded` event sums the fed tokens of all the
/// generation calls of the submission. A tool loop feeds the whole render
/// again at each call, so that sum is not the size of the context. Each
/// `generationCall` event gives the context of one call and the fill of that
/// context over the window. This value keeps the fill of the last call, the
/// largest fill of the prompt, and the window that the calls measure.
struct PromptContextUsage {
    /// The text of a value that no call report gave.
    private static let unknownText = "unknown"

    /// The format of a fill in a log record: a fraction with three decimals.
    private static let fillFormat = "%.3f"

    /// The fill of the newest generation call, or `nil` before the first
    /// call report.
    private var lastCallFill: Double?

    /// The largest fill of all generation calls of the prompt, or `nil`
    /// before the first call report.
    private var peakFill: Double?

    /// The context window, in tokens, that a generation call measured, or
    /// `nil` when no call measured it.
    private(set) var windowTokens: Int?

    /// Records the usage report of one generation call.
    ///
    /// The fill of a call is its context over the window, so the window is
    /// the context of the call divided by its fill. A call with a fill of
    /// zero gives no window. A fill that is not finite is not a measurement,
    /// and this function ignores it.
    ///
    /// - Parameter call: The usage report of the call.
    mutating func record(_ call: GenerationCallUsage) {
        let fill = call.contextFill
        guard fill.isFinite else { return }
        lastCallFill = fill
        peakFill = max(peakFill ?? fill, fill)
        if fill > 0 {
            windowTokens = Int((Double(call.contextTokens) / fill).rounded())
        }
    }

    /// The tokens that `fill` of the window holds.
    ///
    /// - Parameter fill: A fraction of the window.
    /// - Returns: The tokens, or `nil` when no call measured the window, or
    ///   when `fill` is not a finite fraction more than zero.
    func tokens(atFill fill: Double) -> Int? {
        guard let windowTokens, fill.isFinite, fill > 0 else { return nil }
        return Int((fill * Double(windowTokens)).rounded())
    }

    /// The fill of the last call, the peak fill and the window, as log
    /// metadata. A value that no call report gave reads `unknown`.
    var metadata: Logger.Metadata {
        typealias Key = ACPAgentTelemetry.LogMetadataKey
        return [
            Key.lastCallContextFill: "\(Self.fillText(lastCallFill))",
            Key.peakContextFill: "\(Self.fillText(peakFill))",
            Key.contextTokens: "\(windowTokens.map(String.init) ?? Self.unknownText)",
        ]
    }

    /// The text of `fill` in a log record.
    ///
    /// - Parameter fill: A fraction of the window, or `nil`.
    /// - Returns: The fraction with three decimals, or `unknown` for `nil`.
    private static func fillText(_ fill: Double?) -> String {
        fill.map { String(format: fillFormat, $0) } ?? unknownText
    }
}

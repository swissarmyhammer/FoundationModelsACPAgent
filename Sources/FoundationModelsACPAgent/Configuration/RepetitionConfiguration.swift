import Foundation
import FoundationModelsRouter

// MARK: - repetition

/// The `repetition:` section: the settings of Router's repetition detector
/// (task ^k51h6bb).
///
/// A reasoning model can write the lines that it already wrote again, until
/// the call reaches its ceiling. Router watches each generate call, stops a
/// call when one window of generated tokens holds no new line, and runs a
/// recovery submission. A prompt whose last submission stopped this way,
/// with no recovery left, ends with the `_repeated` stop reason. Router also
/// stops a pass that reasons past ``reasoningTokenLimit``, and such a prompt
/// ends with the `_reasoning_limit` stop reason (task ^7fsfw7y).
///
/// Each key is the name of a property of Router's `RepetitionDetection`,
/// and each default is Router's own named default. So a `config.yaml` with
/// no `repetition:` section gives the same detector as a session that
/// passes no detection.
public struct RepetitionConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
    /// Whether the session watches the calls of its submissions. When
    /// `false`, no call stops for repetition, and no pass token limit applies.
    public var isEnabled = RepetitionDetection.defaultIsEnabled

    /// The window, in generated tokens, that must hold at least one new line.
    public var windowTokens = RepetitionDetection.defaultWindowTokens

    /// The minimum length, in characters, of a line that counts.
    public var minimumLineLength = RepetitionDetection.defaultMinimumLineLength

    /// How many times one answer goes on after a repetition stop.
    public var recoveriesPerAnswer = RepetitionDetection.defaultRecoveriesPerAnswer

    /// The most output tokens that one generation pass may make when the
    /// caller names no ceiling.
    public var passTokenLimit = RepetitionDetection.defaultPassTokenLimit

    /// Whether the detector compares the shape of each line, and not its
    /// exact text: the shape replaces each run of digits with one `#`, so
    /// lines that differ only in a number are repeats (task ^7fsfw7y).
    public var comparesLineShapes = RepetitionDetection.defaultComparesLineShapes

    /// How many times one short line shape can occur in a call before it
    /// counts (task ^7fsfw7y). A shape is short when it is shorter than
    /// ``minimumLineLength``.
    public var shortLineRepeatThreshold = RepetitionDetection.defaultShortLineRepeatThreshold

    /// The most reasoning tokens of one generation pass, or `nil` for no
    /// limit (task ^7fsfw7y). A `null` in `config.yaml` gives `nil`, and
    /// Router also reads `0` as no limit. An absent key keeps Router's
    /// default limit. A prompt whose last pass reasoned past the limit, with
    /// no recovery left, ends with the `_reasoning_limit` stop reason.
    public var reasoningTokenLimit: Int? = RepetitionDetection.defaultReasoningTokenLimit

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case isEnabled, windowTokens, minimumLineLength, recoveriesPerAnswer, passTokenLimit
        case comparesLineShapes, shortLineRepeatThreshold, reasoningTokenLimit
    }

    /// Router's default detector.
    public init() {}

    /// Decodes each present key and keeps Router's default for each absent
    /// one. A `reasoningTokenLimit` that is present and `null` is `nil`: no
    /// limit.
    ///
    /// - Parameter decoder: The decoder of the section.
    /// - Throws: `DecodingError` when a value has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        windowTokens = try container.decodeIfPresent(Int.self, forKey: .windowTokens) ?? windowTokens
        minimumLineLength =
            try container.decodeIfPresent(Int.self, forKey: .minimumLineLength) ?? minimumLineLength
        recoveriesPerAnswer =
            try container.decodeIfPresent(Int.self, forKey: .recoveriesPerAnswer) ?? recoveriesPerAnswer
        passTokenLimit = try container.decodeIfPresent(Int.self, forKey: .passTokenLimit) ?? passTokenLimit
        comparesLineShapes =
            try container.decodeIfPresent(Bool.self, forKey: .comparesLineShapes) ?? comparesLineShapes
        shortLineRepeatThreshold =
            try container.decodeIfPresent(Int.self, forKey: .shortLineRepeatThreshold)
            ?? shortLineRepeatThreshold
        if container.contains(.reasoningTokenLimit) {
            reasoningTokenLimit = try container.decodeIfPresent(Int.self, forKey: .reasoningTokenLimit)
        }
    }

    /// The detection a session gets from this section.
    public var detection: RepetitionDetection {
        RepetitionDetection(
            isEnabled: isEnabled,
            windowTokens: windowTokens,
            minimumLineLength: minimumLineLength,
            recoveriesPerAnswer: recoveriesPerAnswer,
            passTokenLimit: passTokenLimit,
            comparesLineShapes: comparesLineShapes,
            shortLineRepeatThreshold: shortLineRepeatThreshold,
            reasoningTokenLimit: reasoningTokenLimit)
    }
}

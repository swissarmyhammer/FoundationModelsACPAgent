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
/// with no recovery left, ends with the `_repeated` stop reason.
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

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case isEnabled, windowTokens, minimumLineLength, recoveriesPerAnswer, passTokenLimit
    }

    /// Router's default detector.
    public init() {}

    /// Decodes each present key and keeps Router's default for each absent
    /// one.
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
    }

    /// The detection a session gets from this section.
    public var detection: RepetitionDetection {
        RepetitionDetection(
            isEnabled: isEnabled,
            windowTokens: windowTokens,
            minimumLineLength: minimumLineLength,
            recoveriesPerAnswer: recoveriesPerAnswer,
            passTokenLimit: passTokenLimit)
    }
}

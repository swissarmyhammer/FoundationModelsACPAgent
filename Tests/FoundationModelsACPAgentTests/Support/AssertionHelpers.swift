import Foundation
import FoundationModelsACP
import Testing

/// The kind of one `SessionUpdate`, for filtering a collected sequence
/// by discriminator instead of by full payload.
enum SessionUpdateKind: Sendable, Hashable {
    case userMessageChunk
    case userMessage
    case agentMessageChunk
    case agentMessage
    case agentThoughtChunk
    case agentThought
    case stateUpdate
    case toolCallContentChunk
    case toolCallUpdate
    case terminalUpdate
    case terminalOutputChunk
    case planUpdate
    case availableCommandsUpdate
    case configOptionUpdate
    case sessionInfoUpdate
    case usageUpdate
    case unknown
}

extension SessionUpdate {
    /// The kind of this update.
    ///
    /// The switch is exhaustive with no `default` arm: the wire union
    /// carries its own `unknown` case for an unlisted variant, and a new
    /// listed case must be mapped here deliberately.
    var kind: SessionUpdateKind {
        switch self {
        case .userMessageChunk: .userMessageChunk
        case .userMessage: .userMessage
        case .agentMessageChunk: .agentMessageChunk
        case .agentMessage: .agentMessage
        case .agentThoughtChunk: .agentThoughtChunk
        case .agentThought: .agentThought
        case .stateUpdate: .stateUpdate
        case .toolCallContentChunk: .toolCallContentChunk
        case .toolCallUpdate: .toolCallUpdate
        case .terminalUpdate: .terminalUpdate
        case .terminalOutputChunk: .terminalOutputChunk
        case .planUpdate: .planUpdate
        case .availableCommandsUpdate: .availableCommandsUpdate
        case .configOptionUpdate: .configOptionUpdate
        case .sessionInfoUpdate: .sessionInfoUpdate
        case .usageUpdate: .usageUpdate
        case .unknown: .unknown
        }
    }
}

extension UpdateCollector {
    /// The collected notifications whose update has `kind`, in arrival
    /// order.
    ///
    /// - Parameter kind: The kind to keep.
    /// - Returns: The matching notifications.
    func updates(ofKind kind: SessionUpdateKind) -> [UpdateSessionNotification] {
        updates.filter { $0.update.kind == kind }
    }
}

/// The turn updates of a collected sequence: every notification except
/// the `available_commands_update` publications, which ride the same
/// stream at session start and on each registry change (plan.md §14.4).
/// A turn-order proof filters them out, because their timing is the
/// registry's, not the turn's.
///
/// - Parameter updates: The collected notifications.
/// - Returns: The notifications that belong to a turn.
func turnUpdates(in updates: [UpdateSessionNotification]) -> [UpdateSessionNotification] {
    updates.filter { $0.update.kind != .availableCommandsUpdate }
}

/// Asserts that `expected` occurs within `sequence` in order, with gaps
/// permitted — the shape of a turn-order proof over a collected
/// notification sequence.
///
/// - Parameters:
///   - expected: The elements that must appear, in this order.
///   - sequence: The full sequence to search.
///   - sourceLocation: The test line a failure is reported at.
func expectOrderedSubsequence<Element: Equatable>(
    _ expected: [Element],
    in sequence: [Element],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var remaining = expected[...]
    for element in sequence {
        guard let next = remaining.first else { break }
        if next == element {
            remaining.removeFirst()
        }
    }
    #expect(
        remaining.isEmpty,
        "expected \(expected) in order within \(sequence); not found from \(Array(remaining))",
        sourceLocation: sourceLocation)
}

/// The JSON text of one encodable wire value, for a contains assertion
/// over everything the value carries.
///
/// - Parameter value: The value to encode.
/// - Returns: The JSON text.
/// - Throws: The encoding error.
func encodedWireText(of value: some Encodable) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

/// Reads one string field of a wire error's `data` object, so a refusal
/// assertion names the id or reason the error carried (plan.md §10.1).
///
/// - Parameters:
///   - name: The field name.
///   - error: The wire error.
/// - Returns: The string value, or `nil` when absent.
func errorDataField(_ name: String, of error: RequestError) -> String? {
    guard case .object(let fields) = error.data ?? .null,
        case .string(let value) = fields[name] ?? .null
    else {
        return nil
    }
    return value
}

/// Reads the UTF-8 text of the file at `url` from disk.
///
/// The disk is the truth a tool-call claim is checked against
/// (plan.md §20.1): never trust a `tool_call_update` that says a file
/// was written — read the file.
///
/// - Parameter url: The file to read.
/// - Returns: The file's text.
/// - Throws: The read error when the file does not exist or does not
///   decode as UTF-8.
func textOnDisk(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

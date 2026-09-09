import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsRouter

/// One recorded `transcript.jsonl` line, in the fields the transcript
/// proofs read.
///
/// The typed `TranscriptEvent` read cannot answer every proof: Router keeps
/// `TranscriptEntryPayload.toolCalls` and the entry id internal, so the
/// `argumentsJSON` of a recorded call, and the call an output answers, are
/// reachable only from the file on disk. That is also the honest place to
/// read them, because the file is what a later session restores from.
struct RecordedTranscriptLine: Decodable {
    /// One recorded tool call of a `toolCalls` entry.
    struct ToolCall: Decodable {
        /// The call's own id. The answering `toolOutput` entry carries the
        /// same value as its entry id.
        let id: String

        /// The name of the called tool.
        let toolName: String

        /// The call's arguments, as the recorded JSON string.
        let argumentsJSON: String
    }

    /// One recorded segment of an entry.
    struct Segment: Decodable {
        /// The text of a `text` segment.
        let content: String?

        /// The schema name of a `structure` segment.
        let schemaName: String?

        /// The body of a `structure` segment, as the recorded JSON string.
        let contentJSON: String?
    }

    /// One recorded tool definition of an `instructions` entry.
    struct ToolDefinition: Decodable {
        /// The declared tool's name.
        let name: String

        /// The tool's parameter schema, as the recorded JSON string.
        let parametersSchemaJSON: String
    }

    /// The recorded entry body of one event.
    struct Entry: Decodable {
        /// Apple's own entry id. On a `toolOutput` entry that answers a
        /// call directly, it is the id of the answered call.
        let entryId: String?

        /// The tool calls a `toolCalls` entry requested.
        let toolCalls: [ToolCall]?

        /// The tool definitions an `instructions` entry declared.
        let toolDefinitions: [ToolDefinition]?

        /// The entry's segments, in order.
        let segments: [Segment]?
    }

    /// The id of the session the event belongs to.
    let sessionId: String

    /// The event's kind, as the recorded string.
    let kind: String

    /// The event's flattened text, when it carries any.
    let text: String?

    /// The mirrored transcript entry, for an entry-kind event.
    let entry: Entry?
}

/// The reader of the recorded `transcript.jsonl` files of one recording root.
enum RecordedTranscriptFile {
    /// The name of the file the recorder appends to.
    static let fileName = "transcript.jsonl"

    /// The `toolCalls` kind string.
    static let toolCallsKind = "toolCalls"

    /// The `toolOutput` kind string.
    static let toolOutputKind = "toolOutput"

    /// The envelope field that names the background run a `wait` collects.
    /// It holds the same value as the `correlationID` of every operation
    /// event the run posts, so it joins a recorded call to its outcome.
    static let completionTokenKey = "completionToken"

    /// How many times a reader unwraps a JSON text that is itself carried
    /// as a JSON string. A recorded structured segment wraps its body one
    /// time; the bound leaves room for one more layer.
    private static let maxEnvelopeUnwraps = 3

    /// The recorded lines of one session, read from every recording file
    /// under `root`.
    ///
    /// - Parameters:
    ///   - root: The recording root to read.
    ///   - sessionId: The session whose lines to keep.
    /// - Returns: The session's lines, in file order.
    /// - Throws: The read or the decode error.
    static func lines(
        under root: URL, sessionId: SessionId
    ) throws -> [RecordedTranscriptLine] {
        let decoder = JSONDecoder()
        let lines = try fileURLs(under: root).flatMap { url -> [RecordedTranscriptLine] in
            let text = try String(contentsOf: url, encoding: .utf8)
            return try text.split(separator: "\n").map { line in
                try decoder.decode(RecordedTranscriptLine.self, from: Data(line.utf8))
            }
        }
        return lines.filter { $0.sessionId == sessionId.rawValue }
    }

    /// Every recording file under `root`, at any depth.
    ///
    /// - Parameter root: The recording root to walk.
    /// - Returns: The file URLs, in walk order.
    static func fileURLs(under root: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let contents = walker?.compactMap { $0 as? URL } ?? []
        return contents.filter { $0.lastPathComponent == fileName }
    }

    /// The file Router records one session to: `<root>/<sessionId>/`, and
    /// ``fileName`` inside it.
    ///
    /// - Parameters:
    ///   - root: The recording root the session was given.
    ///   - sessionId: The session's own id.
    /// - Returns: The file URL, whether or not anything stands there.
    static func fileURL(under root: URL, sessionId: String) -> URL {
        root
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The lines of one recorded kind.
    ///
    /// - Parameters:
    ///   - kind: The recorded kind string to keep.
    ///   - lines: The session's recorded lines.
    /// - Returns: The matching lines, in order.
    static func lines(
        ofKind kind: String, in lines: [RecordedTranscriptLine]
    ) -> [RecordedTranscriptLine] {
        lines.filter { $0.kind == kind }
    }

    /// The completion token of the background run one recorded call
    /// started: the token the answering `toolOutput` entry carries in its
    /// pending envelope.
    ///
    /// - Parameters:
    ///   - callId: The id of the call the output answers.
    ///   - lines: The session's recorded lines.
    /// - Returns: The token, or `nil` when no answering output names one.
    static func completionToken(
        answering callId: String, in lines: [RecordedTranscriptLine]
    ) -> String? {
        let bodies = self.lines(ofKind: toolOutputKind, in: lines)
            .filter { $0.entry?.entryId == callId }
            .flatMap { $0.entry?.segments ?? [] }
            .compactMap { $0.contentJSON ?? $0.content }
        return bodies.compactMap(completionToken(inEnvelope:)).first
    }

    /// The completion token one recorded envelope names.
    ///
    /// A recorded structured segment carries its body as a JSON string, so
    /// the envelope is one JSON text inside another. The reader unwraps a
    /// string value and looks again, up to ``maxEnvelopeUnwraps`` times.
    ///
    /// - Parameter envelope: The recorded segment body.
    /// - Returns: The token, or `nil` when the body names none.
    static func completionToken(inEnvelope envelope: String) -> String? {
        var current: String? = envelope
        for _ in 0..<maxEnvelopeUnwraps {
            let value = current.flatMap(jsonValue(in:))
            if let token = (value as? [String: Any])?[completionTokenKey] as? String {
                return token
            }
            current = value as? String
        }
        return nil
    }

    /// The top-level object of a JSON text.
    ///
    /// - Parameter text: The JSON text to read.
    /// - Returns: The object's fields, or `nil` when the text is not a
    ///   JSON object.
    static func jsonObject(in text: String) -> [String: Any]? {
        jsonValue(in: text) as? [String: Any]
    }

    /// One JSON text, parsed. Fragments are allowed, so a text that is one
    /// JSON string reads back as that string.
    ///
    /// - Parameter text: The JSON text to read.
    /// - Returns: The parsed value, or `nil` when the text is not JSON.
    static func jsonValue(in text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }
}

import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// Task ^sg4t8cm: a failed `runCode` run can be read back whole — the
/// snippet the model wrote, and the message the run answered with.
///
/// The defect the card names was corrected in `FoundationModelsRouter`
/// under `^jz016kq`: the differ discarded every turn, so no `toolCalls`
/// entry was ever written and the snippet source went nowhere. These
/// proofs state the three facts that make a failed run readable again:
///
/// 1. A recorded turn that calls `runCode` holds the snippet source.
/// 2. The source and the outcome of ONE call are readable together,
///    over the recorded join this suite documents.
/// 3. An over-long snippet is kept whole. Nothing is dropped, so the
///    record needs no dropped-byte count. If a limit is ever added,
///    proof 3 fails until the record keeps the head AND states how many
///    bytes went away.
///
/// **The join.** No single entry holds both the source and the outcome,
/// so a reader walks three hops:
///
/// 1. the `toolCalls` entry gives the call id and the `argumentsJSON`,
///    whose `code` field is the snippet source;
/// 2. the `toolOutput` entry whose entry id equals that call id answers
///    the call with the run's pending envelope, which carries the
///    `completionToken`;
/// 3. the operation event whose `correlationID` equals that token, and
///    whose kind is `completed`, gives the outcome `detail` — the
///    failure message with the line number in it.
///
/// The model is the scripted backend, so the suite loads no weights and
/// touches no network. The snippets themselves run in the real code-mode
/// sandbox, so proof 2 reads a real failure and not a scripted string.
struct RunCodeSourceTests {
    /// The prompt text of the one driven turn.
    private static let promptText = "run the snippet"

    /// A snippet that computes and reads nothing, so the proof stays
    /// fast.
    private static let workingSnippet = "return 21 + 21;"

    /// A snippet the sandbox refuses to parse. The failure names a line,
    /// which is what makes the source necessary to a reader.
    private static let failingSnippet = "return (;"

    /// The words the parse failure starts with.
    private static let failureOpening = "The snippet failed:"

    /// One line of the over-long snippet. The head of the recorded
    /// source starts with it.
    private static let longSnippetLine = "// one line of the over-long snippet\n"

    /// How many lines the over-long snippet holds. The product is more
    /// than 70,000 bytes, well past any plausible record bound.
    private static let longSnippetLineCount = 2_000

    /// The `runCode` argument that carries the snippet source.
    private static let codeArgumentKey = "code"

    /// The field a BOUNDED record must carry beside the kept head: how
    /// many bytes of the snippet went away. No record writes it today,
    /// because no limit bounds a recorded snippet. Proof 3 asks for it
    /// only when the recorded source is shorter than what was sent.
    private static let droppedByteCountKey = "droppedByteCount"

    // MARK: - One recorded run

    /// What one scripted `runCode` turn left behind.
    private struct RecordedRun {
        /// The session's recorded lines, read from disk.
        let lines: [RecordedTranscriptLine]

        /// The session's recorded events, read through Router's public
        /// merged read. The operation events ride on these.
        let events: [TranscriptEvent]
    }

    /// One recorded `runCode` call: the id the answering output names,
    /// and the snippet source the model wrote.
    private struct RecordedCall {
        /// The call's own id.
        let id: String

        /// The snippet source, decoded from the call's `argumentsJSON`.
        let source: String

        /// How many bytes of the source the record says went away, or
        /// `nil` when the record states no count.
        let droppedByteCount: Int?
    }

    /// Drives one scripted turn that calls `runCode` with `code`, waits
    /// for the run to settle, and reads the recording back.
    ///
    /// - Parameters:
    ///   - code: The snippet the scripted call carries.
    ///   - label: The directory label of the calling proof.
    /// - Returns: The recorded lines and events of the session.
    /// - Throws: Whatever the wiring, the turn, or the recording read
    ///   throws.
    private static func runOneTurn(code: String, label: String) async throws -> RecordedRun {
        let fixture = try await ScriptedTurnFixture.make(
            script: try ScriptedTurnFixture.makeToolTurnScript(code: code), label: label)
        let root = try ResumeSessionFixture.projectRecordingRoot(of: fixture.cwd)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: promptText))
        _ = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: fixture.sessionId, count: 1)
        await fixture.close()

        return RecordedRun(
            lines: try RecordedTranscriptFile.lines(under: root, sessionId: fixture.sessionId),
            events: try ResumeSessionFixture.recordedEvents(
                under: root, sessionId: fixture.sessionId))
    }

    // MARK: - The join

    /// Hop 1: the recorded `runCode` call, with the snippet source
    /// decoded out of its arguments.
    ///
    /// - Parameter lines: The session's recorded lines.
    /// - Returns: The call's id and its snippet source.
    /// - Throws: When no `runCode` call is recorded, or its arguments
    ///   carry no `code` field.
    private static func recordedCall(in lines: [RecordedTranscriptLine]) throws -> RecordedCall {
        let calls = RecordedTranscriptFile.lines(
            ofKind: RecordedTranscriptFile.toolCallsKind, in: lines
        )
        .flatMap { $0.entry?.toolCalls ?? [] }
        let call = try #require(
            calls.first { $0.toolName == ScriptedTurnFixture.runCodeToolName },
            "the recording holds no runCode call")
        let arguments = try #require(
            RecordedTranscriptFile.jsonObject(in: call.argumentsJSON),
            "the recorded runCode arguments are not a JSON object")
        let source = try #require(
            arguments[codeArgumentKey] as? String,
            "the recorded runCode arguments carry no \(codeArgumentKey) field")
        return RecordedCall(
            id: call.id,
            source: source,
            droppedByteCount: arguments[droppedByteCountKey] as? Int)
    }

    /// Hop 2: the completion token of the run one recorded call started.
    ///
    /// - Parameters:
    ///   - callId: The id of the call the output answers.
    ///   - lines: The session's recorded lines.
    /// - Returns: The run's completion token.
    /// - Throws: When no output answers the call with an envelope that
    ///   names a token.
    private static func completionToken(
        answering callId: String, in lines: [RecordedTranscriptLine]
    ) throws -> String {
        try #require(
            RecordedTranscriptFile.completionToken(answering: callId, in: lines),
            """
            no recorded output answering \(callId) names a \
            \(RecordedTranscriptFile.completionTokenKey)
            """)
    }

    /// Hop 3: the outcome detail of one settled run.
    ///
    /// - Parameters:
    ///   - token: The run's completion token, which every event of the
    ///     run carries as its `correlationID`.
    ///   - events: The session's recorded events.
    /// - Returns: The detail of the run's completion event.
    /// - Throws: When the run recorded no completion event.
    private static func completedDetail(
        forToken token: String, in events: [TranscriptEvent]
    ) throws -> String {
        let completions = events.flatMap(\.operationEvents)
            .filter { $0.correlationID == token && $0.kind == .completed }
        return try #require(
            completions.first?.detail,
            "the run \(token) recorded no completion event")
    }

    // MARK: - The proofs

    @Test("a recorded runCode turn holds the snippet source", .timeLimit(.minutes(1)))
    func theRecordedTurnHoldsTheSnippetSource() async throws {
        let run = try await Self.runOneTurn(
            code: Self.workingSnippet, label: "RunCodeSourceTests-source")

        let call = try Self.recordedCall(in: run.lines)
        #expect(call.source == Self.workingSnippet)
    }

    /// The proof the card was written for: a snippet that fails names a
    /// line, and the reader can reach the line it names.
    @Test("a failed run reads back its source and its failure", .timeLimit(.minutes(1)))
    func aFailedRunReadsBackItsSourceAndItsFailure() async throws {
        let run = try await Self.runOneTurn(
            code: Self.failingSnippet, label: "RunCodeSourceTests-failure")

        let call = try Self.recordedCall(in: run.lines)
        let token = try Self.completionToken(answering: call.id, in: run.lines)
        let detail = try Self.completedDetail(forToken: token, in: run.events)

        #expect(call.source == Self.failingSnippet)
        #expect(detail.hasPrefix(Self.failureOpening))
    }

    /// The size rule: never keep nothing.
    ///
    /// No limit bounds a recorded snippet today, so the whole source
    /// comes back and there is no dropped-byte count to read. Should a
    /// limit ever be added, the record must keep the head and state how
    /// many bytes went away, and this proof holds it to that.
    @Test("an over-long snippet keeps at least its head", .timeLimit(.minutes(1)))
    func anOverLongSnippetKeepsAtLeastItsHead() async throws {
        let snippet =
            String(repeating: Self.longSnippetLine, count: Self.longSnippetLineCount)
            + Self.workingSnippet
        let run = try await Self.runOneTurn(code: snippet, label: "RunCodeSourceTests-long")

        let call = try Self.recordedCall(in: run.lines)
        #expect(!call.source.isEmpty, "the record kept nothing of the snippet")
        #expect(snippet.hasPrefix(call.source), "the record kept something other than the head")
        if call.source == snippet {
            #expect(call.droppedByteCount == nil)
        } else {
            let dropped = snippet.utf8.count - call.source.utf8.count
            #expect(
                call.droppedByteCount == dropped,
                "the record bounded the snippet and did not state the dropped byte count")
        }
    }
}

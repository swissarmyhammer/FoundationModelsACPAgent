import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The agent-side half of task ^jz016kq: the recording of a scripted
/// multi-turn session is faithful.
///
/// The defect this suite guards was found in `FoundationModelsRouter` and
/// corrected there: one unchanged `instructions` entry encoded to
/// different bytes on two readings, the baseline check called that a
/// rewrite, and the turn's entries went nowhere. These proofs read the
/// recording this package writes and state five facts about it:
///
/// 1. Two turns record no `divergence` event while the tool surface
///    stands unchanged.
/// 2. One turn is recorded whole: its `prompt`, its `toolCalls` entry
///    with the `runCode` arguments, and its `response` with an entry.
/// 3. `SessionEvent.toolCall` reaches the wire for the `runCode` call.
/// 4. The recorded event count never falls between two reads of one
///    session.
/// 5. Two sessions over the same tool surface record byte-identical
///    tool definitions in their `instructions` entry.
///
/// The model is the scripted backend, so the suite loads no weights and
/// touches no network.
struct TranscriptFidelityTests {
    /// The text the scripted model streams before it calls its tool. A
    /// turn with text gives the `response` entry a non-empty segment.
    private static let replyText = "the snippet ran"

    /// The snippet the scripted `runCode` call carries. It computes in
    /// the sandbox and reads nothing, so the proof stays fast.
    private static let snippetCode = "return 1 + 1;"

    /// The prompt text of every driven turn. Each turn appends its own
    /// ordinal, so the two turns carry different text.
    private static let promptText = "run the snippet, turn "

    /// The scripted id of the turn's first tool call — the `runCode`
    /// call. The scripted backend mints ids by ordinal.
    private static let runCodeCallId = ScriptedSessionBackend.scriptedCallIdPrefix + "1"

    /// The `prompt` kind string.
    private static let promptKind = "prompt"

    /// The `response` kind string.
    private static let responseKind = "response"

    /// The `instructions` kind string.
    private static let instructionsKind = "instructions"

    // MARK: - One two-turn run

    /// What one two-turn scripted run left behind.
    private struct FidelityRun {
        /// The wire notifications the client collected, in arrival
        /// order.
        let updates: [UpdateSessionNotification]

        /// The session's recorded events after the first turn.
        let eventsAfterFirstTurn: [TranscriptEvent]

        /// The session's recorded events after the second turn.
        let eventsAfterSecondTurn: [TranscriptEvent]

        /// The session's recorded lines, read from disk after the
        /// second turn.
        let recordedLines: [RecordedTranscriptLine]
    }

    /// Drives two scripted turns over one session and reads the
    /// recording after each of them.
    ///
    /// - Parameter label: The directory label of the calling proof.
    /// - Returns: The run's wire notifications and recorded events.
    /// - Throws: Whatever the wiring, a turn, or the recording read
    ///   throws.
    private static func runTwoTurns(label: String) async throws -> FidelityRun {
        let script =
            [ScriptedTurnStep.textDelta(replyText)]
            + (try ScriptedTurnFixture.makeToolTurnScript(code: snippetCode))
        let fixture = try await ScriptedTurnFixture.make(script: script, label: label)
        let root = try ResumeSessionFixture.projectRecordingRoot(of: fixture.cwd)

        try await driveTurn(fixture, sessionId: fixture.sessionId, ordinal: 1, idleCount: 1, root: root)
        let afterFirst = try ResumeSessionFixture.recordedEvents(
            under: root, sessionId: fixture.sessionId)
        try await driveTurn(fixture, sessionId: fixture.sessionId, ordinal: 2, idleCount: 2, root: root)
        let afterSecond = try ResumeSessionFixture.recordedEvents(
            under: root, sessionId: fixture.sessionId)
        let updates = await fixture.collector.updates
        await fixture.close()

        return FidelityRun(
            updates: updates,
            eventsAfterFirstTurn: afterFirst,
            eventsAfterSecondTurn: afterSecond,
            recordedLines: try RecordedTranscriptFile.lines(
                under: root, sessionId: fixture.sessionId))
    }

    /// Prompts one turn and waits until its response is recorded and
    /// the session accepts the next prompt.
    ///
    /// - Parameters:
    ///   - fixture: The wired fixture to drive.
    ///   - sessionId: The session to prompt.
    ///   - ordinal: The one-based number of the turn in that session.
    ///   - idleCount: The number of turn ends the collector holds when
    ///     this turn is over. It counts every session on the wire, and
    ///     `ordinal` counts one session only.
    ///   - root: The recording root the session records under.
    /// - Throws: Whatever the prompt or a wait throws.
    private static func driveTurn(
        _ fixture: ScriptedTurnFixture,
        sessionId: SessionId,
        ordinal: Int,
        idleCount: Int,
        root: URL
    ) async throws {
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(
                sessionId: sessionId, text: promptText + String(ordinal)))
        _ = try await ScriptedTurnFixture.waitForIdle(fixture.collector, count: idleCount)
        try await ResumeSessionFixture.waitForRecordedResponses(
            under: root, sessionId: sessionId, count: ordinal)
        try await ScriptedTurnFixture.waitForAvailability(fixture.harness.agent, sessionId)
    }

    // MARK: - The proofs

    @Test("two turns record no divergence while the tool surface is unchanged", .timeLimit(.minutes(1)))
    func twoTurnsRecordNoDivergence() async throws {
        let run = try await Self.runTwoTurns(label: "TranscriptFidelityTests-divergence")

        #expect(run.eventsAfterSecondTurn.allSatisfy { $0.kind != .divergence })
        // The recording is not empty, so the emptiness of the divergence
        // set is a fact about a real recording.
        #expect(run.eventsAfterSecondTurn.contains { $0.kind == .response })
    }

    @Test("one turn records its prompt, its toolCalls with the arguments, and its response", .timeLimit(.minutes(1)))
    func oneTurnIsRecordedWhole() async throws {
        let run = try await Self.runTwoTurns(label: "TranscriptFidelityTests-whole")

        let prompts = RecordedTranscriptFile.lines(ofKind: Self.promptKind, in: run.recordedLines)
        #expect(prompts.count == 2)
        #expect(prompts.first?.text == Self.promptText + "1")

        let calls = RecordedTranscriptFile.lines(
            ofKind: RecordedTranscriptFile.toolCallsKind, in: run.recordedLines
        )
        .flatMap { $0.entry?.toolCalls ?? [] }
        let runCodeCall = try #require(
            calls.first { $0.toolName == ScriptedTurnFixture.runCodeToolName })
        #expect(runCodeCall.argumentsJSON.contains(Self.snippetCode))

        let responses = RecordedTranscriptFile.lines(
            ofKind: Self.responseKind, in: run.recordedLines)
        #expect(responses.count == 2)
        let response = try #require(responses.first)
        #expect(response.entry?.segments?.isEmpty == false)
        #expect(response.text == Self.replyText)
    }

    @Test("the runCode call reaches the wire as a tool call update", .timeLimit(.minutes(1)))
    func theRunCodeCallReachesTheWire() async throws {
        let run = try await Self.runTwoTurns(label: "TranscriptFidelityTests-wire")

        let creations = run.updates.compactMap { notification -> ToolCallUpdate? in
            guard case .toolCallUpdate(let update) = notification.update,
                update.toolCallId.rawValue == Self.runCodeCallId
            else { return nil }
            return update
        }
        let creation = try #require(creations.first)
        #expect(creation.title == .value(ScriptedTurnFixture.runCodeToolName))
        #expect(String(describing: creation.rawInput).contains(Self.snippetCode))
    }

    @Test("the recorded event count never falls between two reads", .timeLimit(.minutes(1)))
    func theRecordedCountNeverFalls() async throws {
        let run = try await Self.runTwoTurns(label: "TranscriptFidelityTests-count")

        #expect(run.eventsAfterSecondTurn.count > run.eventsAfterFirstTurn.count)
        #expect(
            run.eventsAfterSecondTurn.prefix(run.eventsAfterFirstTurn.count).map(\.seq)
                == run.eventsAfterFirstTurn.map(\.seq))
    }

    /// The byte-identity proof of the `instructions` entry.
    ///
    /// The entry is recorded once per session, so two READINGS of it in
    /// one session leave one recorded line. Two sessions over the same
    /// tool surface leave two lines, and each line carries the
    /// `parametersSchemaJSON` of every declared tool as a string. Equal
    /// strings are equal bytes, which is what the schema encoder must
    /// give for one unchanged surface.
    @Test("two sessions over one tool surface record byte-identical tool definitions", .timeLimit(.minutes(1)))
    func theInstructionsToolDefinitionsAreByteIdentical() async throws {
        let script =
            [ScriptedTurnStep.textDelta(Self.replyText)]
            + (try ScriptedTurnFixture.makeToolTurnScript(code: Self.snippetCode))
        let fixture = try await ScriptedTurnFixture.make(
            script: script, label: "TranscriptFidelityTests-instructions")
        let root = try ResumeSessionFixture.projectRecordingRoot(of: fixture.cwd)
        try await Self.driveTurn(
            fixture, sessionId: fixture.sessionId, ordinal: 1, idleCount: 1, root: root)
        let second = try await fixture.harness.connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path)))
        try await Self.driveTurn(
            fixture, sessionId: second.sessionId, ordinal: 1, idleCount: 2, root: root)
        await fixture.close()

        let firstDefinitions = try Self.toolDefinitions(
            under: root, sessionId: fixture.sessionId)
        let secondDefinitions = try Self.toolDefinitions(under: root, sessionId: second.sessionId)

        #expect(!firstDefinitions.isEmpty)
        // A schema that recorded as the empty-string sentinel would make
        // the comparison below true and prove nothing.
        #expect(firstDefinitions.allSatisfy { !$0.parametersSchemaJSON.isEmpty })
        #expect(firstDefinitions.map(\.name) == secondDefinitions.map(\.name))
        #expect(
            firstDefinitions.map(\.parametersSchemaJSON)
                == secondDefinitions.map(\.parametersSchemaJSON))
    }

    /// The tool definitions of one session's recorded `instructions`
    /// entry.
    ///
    /// - Parameters:
    ///   - root: The recording root to read.
    ///   - sessionId: The session whose entry to read.
    /// - Returns: The declared definitions, in recorded order.
    /// - Throws: The read or the decode error.
    private static func toolDefinitions(
        under root: URL, sessionId: SessionId
    ) throws -> [RecordedTranscriptLine.ToolDefinition] {
        let lines = try RecordedTranscriptFile.lines(under: root, sessionId: sessionId)
        return RecordedTranscriptFile.lines(ofKind: Self.instructionsKind, in: lines)
            .flatMap { $0.entry?.toolDefinitions ?? [] }
    }
}

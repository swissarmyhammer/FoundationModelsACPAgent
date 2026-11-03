import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The scripted stub model of the `acp-agent` binary
/// (`ACP_AGENT_STUB_SCRIPT`): the parse of the script file, the choice of a
/// session by its first prompt, the passes in order, and the gate step.
///
/// The player of the steps is the one of the in-process tests
/// (``ScriptedSessionBackend``), so these suites cover only what the stub
/// path adds: the file and the playbook of sessions.
@Suite struct ScriptedStubModelTests {
    /// A script with one session of one pass of one step, as JSON.
    private static func scriptJSON(step: String) -> Data {
        Data(
            """
            {"sessions":[{"match":{"promptContains":"hello"},"passes":[[\(step)]]}]}
            """.utf8)
    }

    /// The steps of the first pass of the first session of `data`.
    private static func firstPass(of data: Data) throws -> [ScriptedPassStep] {
        try #require(ScriptedStubScript.parse(data).sessions.first?.passes.first)
    }

    // MARK: - The parse

    @Test func aTextStepIsATextDelta() throws {
        let steps = try Self.firstPass(of: Self.scriptJSON(step: #"{"text":"hi"}"#))
        #expect(steps == [.textDelta("hi")])
    }

    @Test func aReasoningStepIsReasoning() throws {
        let steps = try Self.firstPass(of: Self.scriptJSON(step: #"{"reasoning":"think"}"#))
        #expect(steps == [.reasoning("think")])
    }

    @Test func aGateStepIsAGateOnThePath() throws {
        let steps = try Self.firstPass(of: Self.scriptJSON(step: #"{"gate":"/tmp/go"}"#))
        #expect(steps == [.gate(path: "/tmp/go")])
    }

    @Test func aToolCallStepKeepsTheNameAndEncodesTheArguments() throws {
        let steps = try Self.firstPass(
            of: Self.scriptJSON(
                step: #"{"toolCall":{"name":"agents","arguments":{"prompt":"go","operation":"start agent"}}}"#))
        #expect(
            steps == [
                .toolCall(
                    name: "agents", argumentsJSON: #"{"operation":"start agent","prompt":"go"}"#)
            ])
    }

    @Test func theStepsOfAPassKeepTheirOrder() throws {
        let steps = try Self.firstPass(
            of: Self.scriptJSON(step: #"{"reasoning":"a"},{"text":"b"},{"gate":"c"}"#))
        #expect(steps == [.reasoning("a"), .textDelta("b"), .gate(path: "c")])
    }

    @Test func aSessionKeepsItsPassesInOrder() throws {
        let data = Data(
            #"{"sessions":[{"match":{"promptContains":"x"},"passes":[[{"text":"1"}],[{"text":"2"}]]}]}"#.utf8)
        let passes = try #require(ScriptedStubScript.parse(data).sessions.first?.passes)
        #expect(passes == [[.textDelta("1")], [.textDelta("2")]])
    }

    // MARK: - The errors of the parse

    /// The message of the error that `data` gives, or `nil` when it parses.
    private static func parseError(of data: Data) -> String? {
        do {
            _ = try ScriptedStubScript.parse(data)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    @Test func anUnknownStepIsAnErrorThatNamesIt() {
        let message = Self.parseError(of: Self.scriptJSON(step: #"{"shout":"hi"}"#))
        #expect(message?.contains("shout") == true)
    }

    @Test func aStepWithTwoKeysIsAnError() {
        #expect(Self.parseError(of: Self.scriptJSON(step: #"{"text":"a","reasoning":"b"}"#)) != nil)
    }

    @Test func aTextThatIsNotAStringIsAnError() {
        #expect(Self.parseError(of: Self.scriptJSON(step: #"{"text":5}"#)) != nil)
    }

    @Test func aToolCallWithoutArgumentsIsAnError() {
        #expect(Self.parseError(of: Self.scriptJSON(step: #"{"toolCall":{"name":"agents"}}"#)) != nil)
    }

    @Test func aFileThatIsNotJSONIsAnError() {
        #expect(Self.parseError(of: Data("not json".utf8)) != nil)
    }

    @Test func aFileWithoutSessionsIsAnError() {
        let message = Self.parseError(of: Data("{}".utf8))
        #expect(message?.contains("sessions") == true)
    }

    @Test func aSessionWithoutAMatchIsAnError() {
        #expect(Self.parseError(of: Data(#"{"sessions":[{"passes":[]}]}"#.utf8)) != nil)
    }

    @Test func aMissingFileIsAnErrorThatNamesThePath() {
        let path = "/nonexistent/acp-agent-script.json"
        do {
            _ = try ScriptedStubScript.load(fromPath: path)
            Issue.record("A missing file must throw.")
        } catch {
            #expect(String(describing: error).contains(path))
        }
    }

    // MARK: - The choice of a session

    /// A script of two sessions that both match the prompt "shared".
    private static let twoSessions = ScriptedStubScript(sessions: [
        .init(promptContains: "shared", passes: [[.textDelta("first")]]),
        .init(promptContains: "shared", passes: [[.textDelta("second")]]),
        .init(promptContains: "other", passes: [[.textDelta("third")]]),
    ])

    @Test func theFirstMatchingEntryWins() {
        #expect(Self.twoSessions.passes(forFirstPrompt: "a shared prompt") == [[.textDelta("first")]])
    }

    @Test func aLaterEntryMatchesWhenTheEarlierOnesDoNot() {
        #expect(Self.twoSessions.passes(forFirstPrompt: "the other prompt") == [[.textDelta("third")]])
    }

    @Test func aPromptThatMatchesNoEntryHasNoPasses() {
        #expect(Self.twoSessions.passes(forFirstPrompt: "nothing") == nil)
    }

    // MARK: - The playbook of sessions

    /// A backend over the playbook of `script`, with no tools.
    private static func backend(_ script: ScriptedStubScript) -> ScriptedSessionBackend {
        ScriptedSessionBackend(playbook: .sessions(script), tools: [])
    }

    @Test func thePassesPlayInOrderAndTheSessionEchoesAfterTheLastOne() async throws {
        let backend = Self.backend(
            ScriptedStubScript(sessions: [
                .init(promptContains: "go", passes: [[.textDelta("one")], [.textDelta("two")]])
            ]))
        var answers: [String] = []
        for prompt in ["go now", "again", "a third"] {
            answers.append(try await backend.respond(to: prompt, maxTokens: nil))
        }
        #expect(answers == ["one", "two", "a third"])
    }

    @Test func aSessionThatMatchesNothingEchoesEachPrompt() async throws {
        let backend = Self.backend(
            ScriptedStubScript(sessions: [
                .init(promptContains: "go", passes: [[.textDelta("one")]])
            ]))
        let first = try await backend.respond(to: "stray", maxTokens: nil)
        let second = try await backend.respond(to: "go", maxTokens: nil)
        #expect([first, second] == ["stray", "go"])
    }

    @Test func onlyTheFirstPromptChoosesTheSession() async throws {
        let backend = Self.backend(
            ScriptedStubScript(sessions: [
                .init(promptContains: "later", passes: [[.textDelta("matched")]])
            ]))
        _ = try await backend.respond(to: "first", maxTokens: nil)
        let second = try await backend.respond(to: "later", maxTokens: nil)
        #expect(second == "later")
    }

    @Test func eachBackendHasItsOwnProgress() async throws {
        let script = ScriptedStubScript(sessions: [
            .init(promptContains: "go", passes: [[.textDelta("one")], [.textDelta("two")]])
        ])
        let container = ScriptedLLMContainer(playbook: .sessions(script))
        let first = container.makeSession(instructions: nil)
        let second = container.makeSession(instructions: nil)
        _ = try await first.respond(to: "go", maxTokens: nil)
        let answer = try await second.respond(to: "go", maxTokens: nil)
        #expect(answer == "one")
    }

    // MARK: - The gate

    /// The path of a gate file that does not exist, in a new folder.
    private static func gatePath() throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptedStubModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("gate").path
    }

    /// Runs a pass of a reasoning step, then a gate on `path`, then the text
    /// "done". Calls `open` when the pass is at the gate: the reasoning
    /// entry of the transcript is the sign.
    ///
    /// - Returns: The answer, and whether the pass had answered before
    ///   `open` ran.
    private static func runGatedPass(path: String, open: @Sendable () throws -> Void) async throws -> (
        answer: String, answeredBeforeOpen: Bool
    ) {
        let backend = Self.backend(
            ScriptedStubScript(sessions: [
                .init(
                    promptContains: "go",
                    passes: [[.reasoning("at the gate"), .gate(path: path), .textDelta("done")]])
            ]))
        let pass = Task { try await backend.respond(to: "go", maxTokens: nil) }
        await Self.waitForReasoning(of: backend)
        let answeredBeforeOpen = backend.transcriptEntries().contains { entry in
            if case .response = entry { return true }
            return false
        }
        try open()
        return (try await pass.value, answeredBeforeOpen)
    }

    /// Waits until the pass of `backend` made its reasoning entry, which
    /// comes just before the gate.
    private static func waitForReasoning(of backend: ScriptedSessionBackend) async {
        for await entries in backend.transcriptUpdates() {
            let hasReasoning = entries.contains { entry in
                if case .reasoning = entry { return true }
                return false
            }
            if hasReasoning { return }
        }
    }

    @Test func aGateWaitsUntilTheFileExists() async throws {
        let path = try Self.gatePath()
        let result = try await Self.runGatedPass(path: path) {
            try Data().write(to: URL(fileURLWithPath: path))
        }
        #expect(result.answer == "done")
        #expect(!result.answeredBeforeOpen)
    }

    @Test func aGateWaitsForAByteOfANamedPipe() async throws {
        let path = try Self.gatePath()
        #expect(mkfifo(path, 0o600) == 0)
        // The test holds the write end from the start, like the runner of
        // the integration tests. A byte written to a pipe that no process
        // holds open is lost.
        let writer = open(path, O_RDWR)
        defer { close(writer) }
        let result = try await Self.runGatedPass(path: path) {
            var byte: UInt8 = 1
            #expect(write(writer, &byte, 1) == 1)
        }
        #expect(result.answer == "done")
        #expect(!result.answeredBeforeOpen)
    }

    @Test func aGateEndsWhenItsTaskIsCancelled() async throws {
        let path = try Self.gatePath()
        let backend = Self.backend(
            ScriptedStubScript(sessions: [
                .init(promptContains: "go", passes: [[.reasoning("at the gate"), .gate(path: path)]])
            ]))
        let pass = Task { try await backend.respond(to: "go", maxTokens: nil) }
        await Self.waitForReasoning(of: backend)
        pass.cancel()
        await #expect(throws: CancellationError.self) { try await pass.value }
    }
}

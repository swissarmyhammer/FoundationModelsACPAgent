import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

// MARK: - The resume model seam (plan.md §7.4, §20.1)
//
// The resume round trips need two things the scripted fixtures do not
// give: a backend that appends real transcript entries on the streaming
// path the prompt turn drives, and a container that observes what a
// restore asks of it. `ScriptedSessionBackend` appends entries only for
// tool calls, and `TranscriptStubBackend` appends only in `respond`, so
// this file adds the resume-shaped pair.

/// A session backend for the resume round trips: every generating call
/// appends one `.prompt`, one `.reasoning`, and one `.response` entry, so
/// a routed session over it records real prompt, reasoning, and response
/// events through every generation surface — `streamResponse` included,
/// which the prompt turn drives.
final class ResumeStubBackend: LanguageModelSessionBackend {
    /// The prefix of every reply, so a test matches the reply text.
    static let replyPrefix = "echo: "

    /// The prefix of every reasoning entry.
    static let reasoningPrefix = "thinking about "

    /// The synthetic transcript so far, guarded for the sync
    /// `transcriptEntries()` read against the async playback append.
    private let entries: Mutex<[Transcript.Entry]>

    /// Makes a backend seeded with `entries` — empty for a fresh session,
    /// and the reconstructed transcript for a restored one.
    ///
    /// - Parameter entries: The seed transcript.
    init(entries: [Transcript.Entry] = []) {
        self.entries = Mutex(entries)
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        appendTurn(prompt: prompt)
    }

    func respond(
        to prompt: String, following grammar: Grammar, maxTokens: Int?
    ) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(appendTurn(prompt: prompt))
            continuation.finish()
        }
    }

    func makeFork() -> any LanguageModelSessionBackend {
        ResumeStubBackend(entries: entries.withLock { $0 })
    }

    func transcriptEntries() -> [Transcript.Entry] {
        entries.withLock { $0 }
    }

    func usageTokenCounts() -> (input: Int, output: Int)? {
        (1, 1)
    }

    /// Appends the three SDK entries of one turn and returns the reply.
    ///
    /// - Parameter prompt: The prompt the turn answers.
    /// - Returns: The reply text.
    private func appendTurn(prompt: String) -> String {
        let reply = Self.replyPrefix + prompt
        entries.withLock { current in
            current.append(
                .prompt(
                    Transcript.Prompt(segments: [
                        .text(Transcript.TextSegment(content: prompt))
                    ])))
            current.append(
                .reasoning(
                    Transcript.Reasoning(
                        id: UUID().uuidString,
                        segments: [
                            .text(
                                Transcript.TextSegment(
                                    content: Self.reasoningPrefix + prompt))
                        ],
                        signature: nil)))
            current.append(
                .response(
                    Transcript.Response(segments: [
                        .text(Transcript.TextSegment(content: reply))
                    ])))
        }
        return reply
    }
}

/// A resident model container for the resume tests: it vends
/// ``ResumeStubBackend`` sessions, counts every backend request, and
/// records each transcript a restore hands to `makeSession(transcript:)`,
/// so a test asserts on what the restored model actually received —
/// never on a property that merely holds a string.
final class ResumeRecordingContainer: LoadedLLMContainer {
    /// The observations one container accumulates.
    private struct Observations {
        /// How many backends this container was asked for.
        var backendRequestCount = 0

        /// Each transcript a restore handed to `makeSession(transcript:)`,
        /// in arrival order.
        var restoredTranscripts: [Transcript] = []
    }

    /// The guarded observations.
    private let observations = Mutex(Observations())

    /// How many backends this container was asked for.
    var backendRequestCount: Int {
        observations.withLock { $0.backendRequestCount }
    }

    /// Each transcript a restore handed to `makeSession(transcript:)`.
    var restoredTranscripts: [Transcript] {
        observations.withLock { $0.restoredTranscripts }
    }

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeFreshBackend()
    }

    func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        makeFreshBackend()
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        makeRestoredBackend(transcript: transcript)
    }

    func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        makeRestoredBackend(transcript: transcript)
    }

    /// Counts and vends one fresh backend.
    private func makeFreshBackend() -> ResumeStubBackend {
        observations.withLock { $0.backendRequestCount += 1 }
        return ResumeStubBackend()
    }

    /// Counts, records the received transcript, and vends one backend
    /// seeded with it.
    ///
    /// - Parameter transcript: The transcript the restore handed over.
    private func makeRestoredBackend(transcript: Transcript) -> ResumeStubBackend {
        observations.withLock { state in
            state.backendRequestCount += 1
            state.restoredTranscripts.append(transcript)
        }
        return ResumeStubBackend(entries: Array(transcript))
    }
}

/// A tool the resume tests record by name only: the recorded roster keeps
/// tool names, and the missing-tool report compares those names against
/// the resumed roster, so the name is the whole point of this tool.
struct RosterNameTool: FoundationModels.Tool {
    /// The wire arguments; the tool reads nothing from them.
    @Generable
    struct Arguments {}

    /// The recorded roster name.
    let name: String

    let description = "a stub tool the resume tests record on the roster by name"

    func call(arguments: Arguments) async throws -> String {
        name
    }
}

/// One wired resume fixture: the recording container, the scripted-turn
/// harness around an agent whose sessions it backs, and the resolved
/// project recording root.
struct ResumeSessionFixture {
    /// The wired scripted-turn fixture.
    let fixture: ScriptedTurnFixture

    /// The container every session backend of the agent comes from.
    let container: ResumeRecordingContainer

    /// The number of idle updates the fixture has waited for so far.
    /// Each ``runTurn(_:)`` waits for one more.
    private var completedTurnCount = 0

    /// The default project recording root of the fixture's cwd:
    /// `<cwd>/.<name>/transcripts/`.
    var recordingRoot: URL {
        get throws {
            try Self.projectRecordingRoot(of: fixture.cwd)
        }
    }

    /// Wires an agent over a fresh ``ResumeRecordingContainer``,
    /// completes `initialize`, and opens one session.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - workingDirectory: The session working directory, or `nil` to
    ///     make a fresh one.
    ///   - projectConfigYAML: The project `config.yaml` to write before
    ///     `session/new`, or `nil` for none.
    ///   - additionalDirectories: The `session/new` additional roots, or
    ///     `nil` for none.
    /// - Returns: The fixture.
    /// - Throws: Whatever the construction or the handshake throws.
    static func make(
        label: String,
        workingDirectory: URL? = nil,
        projectConfigYAML: String? = nil,
        additionalDirectories: [AbsolutePath]? = nil
    ) async throws -> ResumeSessionFixture {
        let container = ResumeRecordingContainer()
        var loader = StubModelLoader()
        loader.makeLLMContainer = { _ in container }
        let fixture = try await ScriptedTurnFixture.make(
            loader: loader,
            label: label,
            workingDirectory: workingDirectory,
            projectConfigYAML: projectConfigYAML,
            additionalDirectories: additionalDirectories)
        return ResumeSessionFixture(fixture: fixture, container: container)
    }

    /// The default project recording root of `cwd` for the harness
    /// dotfolder name.
    ///
    /// - Parameter cwd: The session working directory.
    /// - Returns: The resolved root.
    /// - Throws: When the harness dotfolder name is refused.
    static func projectRecordingRoot(of cwd: URL) throws -> URL {
        TranscriptLocation.project.recordingRoot(
            workingDirectory: cwd,
            name: try DotfolderName(AgentClientHarness.dotfolderName),
            userDirectory: cwd)
    }

    /// Drives one prompt turn over the wire and waits until the session
    /// accepts the next prompt.
    ///
    /// - Parameter text: The prompt text.
    /// - Throws: Whatever the wire call or the waits throw.
    mutating func runTurn(_ text: String) async throws {
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: text))
        completedTurnCount += 1
        _ = try await ScriptedTurnFixture.waitForIdle(
            fixture.collector, count: completedTurnCount)
        try await ScriptedTurnFixture.waitForAvailability(
            fixture.harness.agent, fixture.sessionId)
    }

    /// The recorded events of one session under `root`, in merged order.
    ///
    /// - Parameters:
    ///   - root: The recording root to read.
    ///   - sessionId: The session whose events to keep.
    /// - Returns: The session's events.
    /// - Throws: Whatever the merged read throws.
    static func recordedEvents(
        under root: URL, sessionId: SessionId
    ) throws -> [TranscriptEvent] {
        guard let id = ULID(ulidString: sessionId.rawValue) else {
            return []
        }
        return try TranscriptEvent.merged(under: root).filter { $0.sessionId == id }
    }

    /// Polls until the session's recording holds `count` response events.
    ///
    /// - Parameters:
    ///   - root: The recording root to read.
    ///   - sessionId: The session to watch.
    ///   - count: The response-event count to wait for.
    /// - Throws: `CancellationError` when the test is cancelled.
    static func waitForRecordedResponses(
        under root: URL, sessionId: SessionId, count: Int
    ) async throws {
        for _ in 0..<ScriptedTurnFixture.maxPollAttempts {
            let responses = try recordedEvents(under: root, sessionId: sessionId)
                .count { $0.kind == .response }
            if responses >= count {
                return
            }
            try await Task.sleep(for: ScriptedTurnFixture.pollInterval)
        }
        Issue.record("the recording never reached \(count) response event(s)")
    }

    /// The resume request for the fixture's own session and cwd.
    ///
    /// - Parameters:
    ///   - cwd: The request cwd, or `nil` for the fixture's own.
    ///   - additionalDirectories: The complete new root set, or `nil`.
    ///   - replayFrom: The replay cursor, or `nil` for no replay.
    /// - Returns: The request.
    /// - Throws: When a path does not form an `AbsolutePath`.
    func makeResumeRequest(
        cwd: URL? = nil,
        additionalDirectories: [AbsolutePath]? = nil,
        replayFrom: ReplayFrom? = nil
    ) throws -> ResumeSessionRequest {
        ResumeSessionRequest(
            cwd: try #require(AbsolutePath(rawValue: (cwd ?? fixture.cwd).path)),
            sessionId: fixture.sessionId,
            additionalDirectories: additionalDirectories,
            replayFrom: replayFrom)
    }
}

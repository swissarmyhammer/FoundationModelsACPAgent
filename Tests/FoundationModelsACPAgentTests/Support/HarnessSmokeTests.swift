import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The arguments of ``PathRecordingTool``: one file path.
@Generable
struct PathRecordingArguments {
    /// The path the scripted tool call carries.
    let path: String
}

/// A tool that records the `path` of each call, in call order.
///
/// The smoke tests hand it to the scripted backend and then assert the
/// call really occurred, with the fixed arguments the script names.
final class PathRecordingTool: Tool, Sendable {
    /// The tool name the script calls.
    static let toolName = "record_path"

    let name = PathRecordingTool.toolName
    let description = "test-only tool that records the path of each call"

    /// Backing storage for ``recordedPaths``.
    private let storage = Mutex<[String]>([])

    /// Every path this tool was called with, in call order.
    var recordedPaths: [String] { storage.withLock { $0 } }

    func call(arguments: PathRecordingArguments) async throws -> String {
        storage.withLock { $0.append(arguments.path) }
        return "recorded"
    }
}

/// The shared harness of plan.md §20.1: construction, the `initialize`
/// round trip from the client end, the session of the stub agent, the
/// coalescing flush, the scripted backend, and the assertion helpers.
@Suite struct HarnessSmokeTests {
    /// The deltas the scripted pass streams, in order.
    static let scriptedDeltas = ["Let me look. ", "Reading the file now."]

    /// The path the scripted tool call fixes.
    static let scriptedPath = "/tmp/scripted-target.txt"

    /// The fixed arguments of the scripted tool call, as JSON.
    static let scriptedArgumentsJSON = #"{"path":"\#(scriptedPath)"}"#

    /// The context window the scripted load requests. The stub loader
    /// ignores it; the value only satisfies the `loadLLM` signature.
    static let scriptedContextWindow = 4096

    /// The script every scripted-backend test plays: two deltas, one known
    /// tool call with fixed arguments, and a pass end.
    static let script: [ScriptedPassStep] = [
        .textDelta(scriptedDeltas[0]),
        .textDelta(scriptedDeltas[1]),
        .toolCall(name: PathRecordingTool.toolName, argumentsJSON: scriptedArgumentsJSON),
        .endPass,
    ]

    // MARK: - Construction and the initialize round trip

    /// The convenience builds the pair and completes an `initialize` round
    /// trip observed from the client end.
    @Test(.timeLimit(.minutes(1)))
    func plainHarnessCompletesAnInitializeRoundTrip() async throws {
        let harness = try await AgentClientHarness.make()
        let response = try await harness.connection.initialize(
            AgentClientHarness.makeInitializeRequest())
        await harness.close()

        #expect(response.protocolVersion == ACPClient.supportedProtocolVersion)
        #expect(response.info == RoutedACPAgent.implementation)
        #expect(harness.collector == nil)
    }

    /// The recording harness completes the same round trip, and the
    /// collector holds no session update, because `initialize` streams
    /// none. No permission request is pending on any session either: the
    /// sandbox is the only gate, and this agent never sends one.
    @Test(.timeLimit(.minutes(1)))
    func recordingHarnessCollectsNoUpdateAcrossInitialize() async throws {
        let harness = try await AgentClientHarness.makeRecording()
        let collector = try #require(harness.collector)
        _ = try await harness.connection.initialize(
            AgentClientHarness.makeInitializeRequest())

        #expect(await collector.updates.isEmpty)
        let pendingPermissionCounts = await MainActor.run {
            harness.client.openSessions.values.map(\.pendingPermissions.count)
        }
        #expect(pendingPermissionCounts.allSatisfy { $0 == 0 })
        await harness.close()
    }

    // MARK: - The stub agent

    /// A session of the stub agent starts no code context. A code context
    /// registers an FSEvents stream, and fseventsd registers the streams of
    /// the whole machine one at a time. Thus each code context that a unit
    /// fixture starts makes each other fixture of a parallel run wait.
    @Test(.timeLimit(.minutes(1)))
    func aStubAgentSessionStartsNoCodeContext() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.endPass], label: "HarnessSmokeTests-no-code-context")
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])

        #expect(entry.surface.codeContextStop == nil)
        await fixture.close()
    }

    // MARK: - The coalescing flush

    /// A streamed chunk stays in the coalescing buffer of the session
    /// model, because the harness clock never fires. The flush helper
    /// drains it. No test sleeps for the cadence.
    ///
    /// The agent end of the wire sends the chunk, and the update tap of the
    /// model tells when it arrived. The tap gives each update before the
    /// model folds it, so the read before the flush sees the buffered state.
    @Test(.timeLimit(.minutes(1)))
    func flushDrainsACoalescedChunkWithoutSleeping() async throws {
        let harness = try await AgentClientHarness.make()
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let cwd = makeResolvedDirectory(label: "HarnessSmokeTests-flush")
        let session = try await harness.client.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path)))
        let arrivals = await session.updateTap()
        let messageId = MessageId(rawValue: "message-1")
        let chunkText = "buffered until the flush"

        try await harness.agentConnection.sessionUpdate(
            UpdateSessionNotification(
                sessionId: await session.sessionId,
                update: .agentMessageChunk(
                    ContentChunk(content: .text(TextContent(text: chunkText)), messageId: messageId))))
        for await case .agentMessageChunk in arrivals {
            break
        }

        let textBeforeFlush = await MainActor.run {
            texts(in: Self.agentMessageContent(of: messageId, in: session))
        }
        #expect(!textBeforeFlush.contains(chunkText))

        await harness.flushPendingChunks()

        let textAfterFlush = await MainActor.run {
            texts(in: Self.agentMessageContent(of: messageId, in: session))
        }
        #expect(textAfterFlush.contains(chunkText))
        await harness.close()
    }

    /// The content of the agent message `messageId` in the transcript of
    /// `session`.
    ///
    /// - Parameters:
    ///   - messageId: The id of the agent message.
    ///   - session: The session model to read.
    /// - Returns: The content of the message, or no block when the
    ///   transcript holds no such message.
    @MainActor
    private static func agentMessageContent(of messageId: MessageId, in session: SessionModel) -> [ContentBlock] {
        session.transcript.flatMap { entry -> [ContentBlock] in
            guard case .agentMessage(let message) = entry, message.messageId == messageId else { return [] }
            return message.content
        }
    }

    /// Joins the text blocks of `content` into one string.
    private func texts(in content: [ContentBlock]) -> String {
        content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
    }

    // MARK: - The scripted backend

    /// The scripted backend, driven directly with no session and no
    /// prompt, emits its scripted deltas in order, performs the known tool
    /// call with the fixed arguments, and then ends the pass: the stream
    /// finishes. No model, no download, no network.
    @Test(.timeLimit(.minutes(1)))
    func scriptedBackendEmitsDeltasToolCallAndPassEnd() async throws {
        let recorder = PathRecordingTool()
        let loader = makeScriptedModelLoader(script: Self.script)
        let container = try await loader.loadLLM(
            ref: "stub/standard", slot: .standard, context: Self.scriptedContextWindow, reporting: { _ in })
        let backend = container.makeSession(instructions: nil, tools: [recorder])

        var deltas: [String] = []
        for try await delta in backend.streamResponse(to: "any prompt", maxTokens: nil) {
            deltas.append(delta)
        }

        #expect(deltas == Self.scriptedDeltas)
        #expect(recorder.recordedPaths == [Self.scriptedPath])
    }

    /// The container writes all four session factories, so the tools
    /// reach a transcript-seeded backend as well. The public default
    /// drops `tools`; a container relying on it would record no call.
    @Test(.timeLimit(.minutes(1)))
    func scriptedContainerHandsToolsToATranscriptSeededBackend() async throws {
        let recorder = PathRecordingTool()
        let container = ScriptedLLMContainer(script: Self.script)
        let backend = container.makeSession(transcript: Transcript(), tools: [recorder])

        let text = try await backend.respond(to: "any prompt", maxTokens: nil)

        #expect(text == Self.scriptedDeltas.joined())
        #expect(recorder.recordedPaths == [Self.scriptedPath])
    }

    /// A scripted tool call that names no handed tool fails the pass
    /// loudly instead of passing silently.
    @Test(.timeLimit(.minutes(1)))
    func scriptedToolCallWithoutItsToolThrows() async throws {
        let container = ScriptedLLMContainer(script: Self.script)
        let backend = container.makeSession(instructions: nil)

        await #expect(throws: ScriptedModelError.unknownTool(PathRecordingTool.toolName)) {
            _ = try await backend.respond(to: "any prompt", maxTokens: nil)
        }
    }

    /// Steps after `.endPass` are never emitted: the pass ended.
    @Test(.timeLimit(.minutes(1)))
    func scriptedStepsAfterThePassEndAreNotEmitted() async throws {
        let trailingDelta = "never emitted"
        let container = ScriptedLLMContainer(
            script: [.textDelta(Self.scriptedDeltas[0]), .endPass, .textDelta(trailingDelta)])
        let backend = container.makeSession(instructions: nil)

        let text = try await backend.respond(to: "any prompt", maxTokens: nil)

        #expect(text == Self.scriptedDeltas[0])
    }

    // MARK: - The assertion helpers

    /// The collector filters by update kind and keeps the arrival order.
    @Test func collectorFiltersUpdatesByKind() async throws {
        let collector = UpdateCollector()
        let sessionId = SessionId(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let chunk = ContentChunk(
            content: .text(TextContent(text: "hello")), messageId: MessageId(rawValue: "message-1"))
        let arrivals: [SessionUpdate] = [
            .agentMessageChunk(chunk), .userMessageChunk(chunk), .agentMessageChunk(chunk),
        ]
        for update in arrivals {
            await collector.append(
                notification: UpdateSessionNotification(sessionId: sessionId, update: update))
        }

        let agentChunkKinds = await collector.updates(ofKind: .agentMessageChunk)
            .map(\.update.kind)
        let userChunkKinds = await collector.updates(ofKind: .userMessageChunk)
            .map(\.update.kind)
        let toolCallUpdates = await collector.updates(ofKind: .toolCallUpdate)

        #expect(agentChunkKinds == [.agentMessageChunk, .agentMessageChunk])
        #expect(userChunkKinds == [.userMessageChunk])
        #expect(toolCallUpdates.isEmpty)
    }

    /// The ordered-subsequence assertion accepts elements in order with
    /// gaps, and records an issue when the order breaks.
    @Test func orderedSubsequenceAssertionChecksOrderWithGaps() {
        expectOrderedSubsequence(["a", "c"], in: ["a", "b", "c"])
        expectOrderedSubsequence([], in: ["a"])

        withKnownIssue("the reversed pair is out of order") {
            expectOrderedSubsequence(["c", "a"], in: ["a", "b", "c"])
        }
    }

    /// The filesystem-truth helper reads the file from disk. A test
    /// checks a written file there, never a `tool_call_update` claim.
    @Test func filesystemTruthHelperReadsTheFileFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessSmokeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("truth.txt")
        let content = "the disk is the truth"
        try content.write(to: file, atomically: true, encoding: .utf8)

        #expect(try textOnDisk(at: file) == content)
    }
}

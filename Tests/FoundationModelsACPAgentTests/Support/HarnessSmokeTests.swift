import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPClient
import FoundationModelsRouter
import Synchronization
import Testing

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
/// round trip from the client end, the coalescing flush, the scripted
/// backend, and the assertion helpers.
@Suite struct HarnessSmokeTests {
    /// The deltas the scripted turn streams, in order.
    static let scriptedDeltas = ["Let me look. ", "Reading the file now."]

    /// The path the scripted tool call fixes.
    static let scriptedPath = "/tmp/scripted-target.txt"

    /// The fixed arguments of the scripted tool call, as JSON.
    static let scriptedArgumentsJSON = #"{"path":"\#(scriptedPath)"}"#

    /// The context window the scripted load requests. The stub loader
    /// ignores it; the value only satisfies the `loadLLM` signature.
    static let scriptedContextWindow = 4096

    /// The script every scripted-backend test plays: two deltas, one known
    /// tool call with fixed arguments, and a turn end.
    static let script: [ScriptedTurnStep] = [
        .textDelta(scriptedDeltas[0]),
        .textDelta(scriptedDeltas[1]),
        .toolCall(name: PathRecordingTool.toolName, argumentsJSON: scriptedArgumentsJSON),
        .endTurn,
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
            harness.client.sessions.values.map(\.pendingPermissionRequests.count)
        }
        #expect(pendingPermissionCounts.allSatisfy { $0 == 0 })
        await harness.close()
    }

    // MARK: - The coalescing flush

    /// A streamed chunk stays in the coalescing buffer, because the
    /// harness clock never fires. The flush helper drains it. No test
    /// sleeps for the cadence.
    @Test(.timeLimit(.minutes(1)))
    func flushDrainsACoalescedChunkWithoutSleeping() async throws {
        let harness = try await AgentClientHarness.make()
        let sessionId = SessionId(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let messageId = MessageId(rawValue: "message-1")
        let chunkText = "buffered until the flush"

        await harness.client.sessionUpdate(
            UpdateSessionNotification(
                sessionId: sessionId,
                update: .agentMessageChunk(
                    ContentChunk(content: .text(TextContent(text: chunkText)), messageId: messageId))))

        let textBeforeFlush = await MainActor.run {
            texts(in: harness.client.session(for: sessionId).messageContent(for: messageId))
        }
        #expect(!textBeforeFlush.contains(chunkText))

        await harness.flushPendingChunks()

        let textAfterFlush = await MainActor.run {
            texts(in: harness.client.session(for: sessionId).messageContent(for: messageId))
        }
        #expect(textAfterFlush.contains(chunkText))
        await harness.close()
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
    /// call with the fixed arguments, and then ends the turn: the stream
    /// finishes. No model, no download, no network.
    @Test(.timeLimit(.minutes(1)))
    func scriptedBackendEmitsDeltasToolCallAndTurnEnd() async throws {
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

    /// A scripted tool call that names no handed tool fails the turn
    /// loudly instead of passing silently.
    @Test(.timeLimit(.minutes(1)))
    func scriptedToolCallWithoutItsToolThrows() async throws {
        let container = ScriptedLLMContainer(script: Self.script)
        let backend = container.makeSession(instructions: nil)

        await #expect(throws: ScriptedModelError.unknownTool(PathRecordingTool.toolName)) {
            _ = try await backend.respond(to: "any prompt", maxTokens: nil)
        }
    }

    /// Steps after `.endTurn` are never emitted: the turn ended.
    @Test(.timeLimit(.minutes(1)))
    func scriptedStepsAfterTheTurnEndAreNotEmitted() async throws {
        let trailingDelta = "never emitted"
        let container = ScriptedLLMContainer(
            script: [.textDelta(Self.scriptedDeltas[0]), .endTurn, .textDelta(trailingDelta)])
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
            await collector.append(UpdateSessionNotification(sessionId: sessionId, update: update))
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

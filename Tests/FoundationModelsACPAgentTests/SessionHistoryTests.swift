import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The retained history of a session (ACP schema-v2.0.0-alpha.7): the file
/// that keeps it beside the transcript, the replay that `session/resume`
/// sends from it, and the write at the end of each prompt.
@Suite struct SessionHistoryTests {
    // MARK: - Constants

    /// The id of the user message in the sample history.
    private static let userMessageId = MessageId(rawValue: "user-message-1")

    /// The id of the agent message in the sample history.
    private static let agentMessageId = MessageId(rawValue: "agent-message-1")

    /// The id of the tool call in the sample history.
    private static let toolCallId = ToolCallId(rawValue: "tool-call-1")

    /// The program name of the tool call in the sample history.
    private static let toolName = "runCode"

    /// The context size of the usage report in the sample history.
    private static let contextSize = 4096

    /// The used tokens of the usage report in the sample history.
    private static let usedTokens = 512

    /// The title of the session information in the sample history.
    private static let sessionTitle = "A sample session"

    /// The name of the one command in the sample history.
    private static let commandName = "help"

    // MARK: - Fixtures

    /// The sample update stream: a user message, an agent message in two
    /// chunks, a tool call, a usage report, the session information, a
    /// command list, and an idle state.
    private static let sampleUpdates: [SessionUpdate] = [
        .userMessage(
            UserMessage(messageId: userMessageId, content: .value([.text(TextContent(text: "Question"))]))),
        .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "Ans")), messageId: agentMessageId)),
        .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "wer")), messageId: agentMessageId)),
        .toolCallUpdate(
            ToolCallUpdate(
                toolCallId: toolCallId, name: .value(toolName), status: .value(.completed),
                title: .value(toolName))),
        .usageUpdate(UsageUpdate(size: contextSize, used: usedTokens)),
        .sessionInfoUpdate(SessionInfoUpdate(title: .value(sessionTitle))),
        .availableCommandsUpdate(
            AvailableCommandsUpdate(
                availableCommands: [AvailableCommand(description: "Lists the commands.", name: commandName)])),
        .stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn))),
    ]

    /// The merged history of ``sampleUpdates``.
    private static var sampleHistory: SessionMergeEngine {
        SessionMergeEngine(replaying: sampleUpdates)
    }

    // MARK: - The history file

    /// A history that the agent writes reads back as the same history: the
    /// same entries, with the same ids, and the same session state.
    @Test func aWrittenHistoryReadsBackWithTheSameEntriesAndIds() throws {
        let directory = makeResolvedDirectory(label: "SessionHistoryTests-roundtrip")

        try SessionHistoryFile.write(Self.sampleHistory, in: directory)
        let read = try #require(try SessionHistoryFile.read(from: directory))

        #expect(read == Self.sampleHistory)
        #expect(read.entries.map(\.id) == [
            .userMessage(Self.userMessageId), .agentMessage(Self.agentMessageId), .toolCall(Self.toolCallId),
        ])
    }

    /// A session directory with no history file holds no history. A session
    /// that an earlier build recorded has no file.
    @Test func aDirectoryWithNoHistoryFileHoldsNoHistory() throws {
        let directory = makeResolvedDirectory(label: "SessionHistoryTests-absent")

        #expect(try SessionHistoryFile.read(from: directory) == nil)
    }

    // MARK: - The replay

    /// The replay from the start sends the full retained history: each
    /// transcript entry as one whole update with its id, then each state
    /// field that has a value.
    @Test func theReplayFromTheStartSendsTheFullHistory() {
        let replay = Self.sampleHistory.replayUpdates(from: .start)

        #expect(replay.map(\.kind) == [
            .userMessage, .agentMessage, .toolCallUpdate, .availableCommandsUpdate, .usageUpdate,
            .sessionInfoUpdate, .stateUpdate,
        ])
        #expect(ReplayedMessage.replayed(in: replay) == [
            ReplayedMessage(kind: .user, id: Self.userMessageId.rawValue, text: "Question"),
            ReplayedMessage(kind: .agent, id: Self.agentMessageId.rawValue, text: "Answer"),
        ])
    }

    // MARK: - The write at the end of a prompt

    /// The end of a prompt writes the history beside the transcript, so a
    /// new process can resume the session with the same ids. The history
    /// holds the user message with the id that the prompt response named.
    @Test(.timeLimit(.minutes(1)))
    func theEndOfAPromptWritesTheHistoryWithTheUserMessageOfTheResponse() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.textDelta("Hello."), .endPass], label: "SessionHistoryTests-prompt-end")
        let response = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "Say hello"))
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        try await ScriptedPromptFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        await fixture.close()

        let written = try #require(try SessionHistoryFile.read(from: entry.transcriptDirectory))
        #expect(written.entry(withID: .userMessage(response.messageId)) != nil)
    }
}

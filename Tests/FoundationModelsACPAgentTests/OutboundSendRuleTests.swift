import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The send rules of `AgentSideConnection.sessionUpdate(_:)`: the connection
/// refuses, with `EncodingError.invalidValue`, a custom stop reason that does
/// not start with `_`, a negative usage `size` or `used`, and a currency that
/// is not three capital letters.
///
/// The agent logs and drops an update that a send rule refuses
/// (`AgentSideConnection.post(_:in:)`), so the client never learns that the
/// prompt ended. Thus each stop reason and each usage value that this agent
/// makes goes through a real connection here, and the send must not throw.
@Suite struct OutboundSendRuleTests {
    // MARK: - Constants

    /// The prefix of a custom stop reason under the ACP extension rule.
    private static let customStopReasonPrefix = "_"

    /// The input tokens of the scripted generation call.
    private static let tokensIn = 150

    /// The output tokens of the scripted generation call.
    private static let tokensOut = 30

    /// The context fill of the scripted generation call, as a fraction of
    /// the context window.
    private static let contextFill = 0.18

    /// The context size before the scripted compaction, in tokens.
    private static let tokensBeforeCompaction = 900

    /// The context size after the scripted compaction, in tokens.
    private static let tokensAfterCompaction = 300

    /// The number of usage updates that the scripted events make: one after
    /// the compaction, and the one meter of the prompt.
    private static let scriptedUsageUpdateCount = 2

    // MARK: - Fixtures

    /// One prompt stop for each case of ``PromptStop``. A case with a value
    /// gets one sample value.
    ///
    /// - Returns: The stops.
    private static func makeEveryStop() -> [PromptStop] {
        let stall = GenerationStall(
            timeWithoutProgress: PromptExecution.stalledGenerationBound,
            timeInFlight: PromptExecution.stalledGenerationBound,
            visibility: .fragments(observed: 0), lastProgress: .callStart)
        return [
            .completed, .refusal, .cancelled, .budgetExhausted, .toolLoopCapped, .noOutput, .truncated,
            .endedInReasoning, .repeated, .reasoningLimit, .stalled(stall), .failed(message: "boom"),
        ]
    }

    /// The usage updates that this agent makes: the meter of a prompt with
    /// one generation call, and the meter after a compaction.
    ///
    /// - Returns: The usage updates, in send order.
    private static func makeEveryUsageUpdate() async -> [UsageUpdate] {
        let updates = await SyntheticPrompt.sentUpdates([
            makeSubmissionStarted(),
            .textDelta("answer"),
            .generationCall(
                GenerationCallUsage(
                    tokensIn: tokensIn, tokensOut: tokensOut, finishReason: .completed, entryKind: .text,
                    contextFill: contextFill)),
            makeSubmissionEnded(TokenUsage(tokensIn: tokensIn, tokensOut: tokensOut, contextFill: contextFill)),
            .compaction(
                CompactionResult(
                    summary: nil, tokensBefore: tokensBeforeCompaction, tokensAfter: tokensAfterCompaction,
                    stagesApplied: ["fold"])),
        ])
        return updates.compactMap(usageReport(of:))
    }

    /// Opens an agent connection over an in-memory transport, runs `body`
    /// with it, and closes it.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - body: The work with the connection.
    /// - Throws: Whatever the construction or `body` throws.
    private static func withConnection(
        label: String, _ body: (AgentSideConnection) async throws -> Void
    ) async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName, cacheDirectory: makeResolvedDirectory(label: label))
        let connection = await AgentSideConnection(stream: agentEnd) { _ in agent }
        try await body(connection)
        await connection.close()
        clientEnd.close()
    }

    /// Sends `update` through `connection` with the send rules.
    ///
    /// - Parameters:
    ///   - update: The update to send.
    ///   - connection: The agent connection.
    /// - Throws: The `EncodingError` of a broken send rule.
    private static func send(_ update: SessionUpdate, through connection: AgentSideConnection) async throws {
        try await connection.sessionUpdate(
            UpdateSessionNotification(sessionId: SessionId(rawValue: syntheticSessionIdValue), update: update))
    }

    // MARK: - The stop reasons

    /// Each custom stop reason of this agent starts with `_`, and the idle of
    /// each prompt stop passes the send rules of the connection.
    @Test(.timeLimit(.minutes(1)))
    func theIdleOfEachPromptStopPassesTheSendRules() async throws {
        let idles = Self.makeEveryStop().map(PromptExecution.idleState(for:))
        let customValues = idles.compactMap { idle -> String? in
            guard case .unknown(let value) = idle.stopReason else { return nil }
            return value
        }

        #expect(!customValues.isEmpty)
        #expect(customValues.allSatisfy { $0.hasPrefix(Self.customStopReasonPrefix) })
        try await Self.withConnection(label: "OutboundSendRuleTests-stop") { connection in
            for idle in idles {
                try await Self.send(.stateUpdate(.idle(idle)), through: connection)
            }
        }
    }

    // MARK: - The usage values

    /// Each usage update of this agent has a `size` and a `used` of zero or
    /// more, and passes the send rules of the connection.
    @Test(.timeLimit(.minutes(1)))
    func eachUsageUpdatePassesTheSendRules() async throws {
        let usages = await Self.makeEveryUsageUpdate()

        #expect(usages.count == Self.scriptedUsageUpdateCount)
        #expect(usages.allSatisfy { $0.size >= 0 && $0.used >= 0 })
        try await Self.withConnection(label: "OutboundSendRuleTests-usage") { connection in
            for usage in usages {
                try await Self.send(.usageUpdate(usage), through: connection)
            }
        }
    }
}

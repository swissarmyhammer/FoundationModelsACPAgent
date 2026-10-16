import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The swift-log records of the session surface.
///
/// Each case makes the agent and the harness inside a `TelemetryCapture`, so
/// each logger that the agent makes writes to the capture of the case. The
/// capture does not keep the logger label, thus the label case reads the label
/// of the logger that the agent makes.
@Suite(.closesHarnesses) struct SessionSurfaceLoggingTests {
    /// A session id that no `session/new` gave.
    private static let unknownSessionIdValue = "session-surface-logging-unknown"

    /// The label of each logger of the prompt execution.
    private static let promptExecutionLoggerLabel = "FoundationModelsACPAgent.PromptExecution"

    /// The label of the scripted fixture of this suite.
    private static let fixtureLabel = "SessionSurfaceLoggingTests"

    /// The prompt text of the running prompt that the cancel stops.
    private static let promptText = "Run one prompt"

    /// A `session/cancel` for an unknown session writes one `notice` record.
    /// The session id is in the metadata of the record, and not in its
    /// message.
    @Test
    func ignoredCancelOfAnUnknownSessionWritesOneNoticeWithTheSessionIdInMetadata() async throws {
        let unknownSessionId = Self.unknownSessionIdValue
        let records = try await TelemetryCapture.run(forbidding: []) { context in
            let harness = try await AgentClientHarness.make()
            try await harness.connection.sessionCancel(
                CancelSessionNotification(sessionId: SessionId(rawValue: unknownSessionId)))
            // The agent runs each notification in its read loop before the
            // next message, so the answer of this request comes after the
            // cancel handler ended.
            _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
            await harness.close()
            return context.logRecords
        }

        let cancelRecords = records.filter {
            $0.metadata[ACPAgentTelemetry.LogMetadataKey.sessionId] == .string(unknownSessionId)
        }
        #expect(cancelRecords.count == 1)
        let record = try #require(cancelRecords.first)
        #expect(record.level == .notice)
        #expect(!"\(record.message)".contains(unknownSessionId))
    }

    /// A `session/cancel` for a session with a running prompt writes one
    /// `info` record. The record holds the session id and the `SignalID` of
    /// the `cancelAll()` signal in its metadata.
    @Test
    func cancelOfARunningPromptWritesOneInfoWithTheCancelSignalInMetadata() async throws {
        let cancelSignalKey = ACPAgentTelemetry.LogMetadataKey.cancelSignalId
        let records = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await ScriptedPromptFixture.make(
                script: [.textDelta("working"), .hold], label: Self.fixtureLabel)
            _ = try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.promptText))
            try await ScriptedPromptFixture.waitForRunning(fixture.collector)
            try await fixture.harness.connection.sessionCancel(
                CancelSessionNotification(sessionId: fixture.sessionId))
            await context.wait { capture in
                capture.logRecords.contains { $0.metadata[cancelSignalKey] != nil }
            }
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            await ScriptedPromptFixture.waitForPromptsFinished(fixture.harness.agent, fixture.sessionId)
            await fixture.close()
            return (sessionId: fixture.sessionId.rawValue, records: context.logRecords)
        }

        let cancelRecords = records.records.filter { $0.metadata[cancelSignalKey] != nil }
        #expect(cancelRecords.count == 1)
        let record = try #require(cancelRecords.first)
        #expect(record.level == .info)
        guard case .string(let signal) = record.metadata[cancelSignalKey] else {
            Issue.record("expected the signal id as a string")
            return
        }
        #expect(ULID(ulidString: signal) != nil)
        #expect(
            record.metadata[ACPAgentTelemetry.LogMetadataKey.sessionId] == .string(records.sessionId))
    }

    /// The logger of the prompt execution has the module label and the
    /// category of the prompt execution.
    @Test func promptExecutionLoggerHasTheModuleLabel() {
        #expect(ACPAgentTelemetry.logger(.promptExecution).label == Self.promptExecutionLoggerLabel)
    }
}

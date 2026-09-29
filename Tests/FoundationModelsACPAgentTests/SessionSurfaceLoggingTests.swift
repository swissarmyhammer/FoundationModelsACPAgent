import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
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
@Suite struct SessionSurfaceLoggingTests {
    /// A session id that no `session/new` gave.
    private static let unknownSessionIdValue = "session-surface-logging-unknown"

    /// The label of each logger of the prompt execution.
    private static let promptExecutionLoggerLabel = "FoundationModelsACPAgent.PromptExecution"

    /// A `session/cancel` for an unknown session writes one `notice` record.
    /// The session id is in the metadata of the record, and not in its
    /// message.
    @Test(.timeLimit(.minutes(1)))
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

    /// The logger of the prompt execution has the module label and the
    /// category of the prompt execution.
    @Test func promptExecutionLoggerHasTheModuleLabel() {
        #expect(ACPAgentTelemetry.logger(.promptExecution).label == Self.promptExecutionLoggerLabel)
    }
}

import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import InMemoryTracing
import TelemetryTestSupport
import Testing
import Tracing

@testable import FoundationModelsACPAgent

/// The server span of each ACP request, and the parent link of the Router
/// spans of a prompt.
///
/// Each case makes the agent and the harness inside a `TelemetryCapture`. The
/// capture binds its tracer with `withTracer`, thus the agent opens its spans
/// through the tracer of the capture. The Router sessions get the same tracer
/// explicitly, and the capture keeps each span that ends.
@Suite struct RequestTracingTests {
    /// The label of the scripted fixture of this suite.
    private static let fixtureLabel = "RequestTracingTests"

    /// The prompt text of the traced prompt. No span and no log record may
    /// hold it.
    private static let promptText = "RequestTracingTests prompt text"

    /// The answer text that the scripted model plays. No span and no log
    /// record may hold it.
    private static let answerText = "RequestTracingTests answer text"

    /// The ACP method of `initialize`.
    private static let initializeMethod = "initialize"

    /// The ACP method of `session/new`.
    private static let sessionNewMethod = "session/new"

    /// The ACP method of `session/resume`.
    private static let sessionResumeMethod = "session/resume"

    /// The ACP method of `session/prompt`.
    private static let sessionPromptMethod = "session/prompt"

    /// The ACP method of `session/cancel`.
    private static let sessionCancelMethod = "session/cancel"

    /// The span name of one Router submission.
    private static let submissionSpanName = "FoundationModelsRouter.submission"

    /// The wire stop reason of a prompt that completed.
    private static let endTurnStopReason = "end_turn"

    /// The full type name of the error that refuses a request for an unknown
    /// session.
    private static let requestErrorTypeName = String(reflecting: RequestError.self)

    /// The text before the span name in the message of an "enter" record.
    private static let enterMessagePrefix = "enter "

    /// A session id that no `session/new` gave.
    private static let unknownSessionIdValue = "request-tracing-unknown"

    /// A session id that has the ULID form, and that no recording holds.
    private static let unrecordedSessionIdValue = "01M3MNF3HX2STG00W3GBT21BAS"

    /// The spans and the log records of one traced run, and the id of its
    /// session.
    private struct TracedRun {
        /// The id of the session of the run.
        let sessionId: String

        /// The spans that ended in the run.
        let spans: [FinishedInMemorySpan]

        /// The message of each log record of the run.
        let logMessages: [String]

        /// Reads the spans and the log records that `context` holds now.
        ///
        /// - Parameters:
        ///   - sessionId: The id of the session of the run.
        ///   - context: The context of the capture of the run.
        init(sessionId: String, context: TelemetryCapture.Context) {
            self.sessionId = sessionId
            spans = context.spans
            logMessages = context.logRecords.map { "\($0.message)" }
        }

        /// The spans with the name `name`.
        ///
        /// - Parameter name: The span name.
        /// - Returns: The spans with that name, in the order of their end.
        func spans(named name: String) -> [FinishedInMemorySpan] {
            spans.filter { $0.operationName == name }
        }

        /// The number of "enter" records of the span with the name `name`.
        ///
        /// - Parameter name: The span name.
        /// - Returns: The number of records with the message `enter <name>`.
        func enterRecordCount(forSpanNamed name: String) -> Int {
            logMessages.count { $0 == RequestTracingTests.enterMessagePrefix + name }
        }
    }

    /// Makes the scripted fixture of this suite inside the capture `context`.
    ///
    /// The Router sessions do their work in a detached task, which does not
    /// get the task-local tracer of the capture. Thus the agent and the Router
    /// get the tracer of the capture explicitly. Each case of this suite makes
    /// its fixture with this function, so that no span goes to a different
    /// tracer.
    ///
    /// - Parameters:
    ///   - script: The steps that the scripted model plays.
    ///   - context: The context of the capture that must keep the spans.
    /// - Returns: The fixture, after `initialize` and `session/new`.
    /// - Throws: Whatever the fixture throws.
    private static func makeTracedFixture(
        script: [ScriptedPassStep], context: TelemetryCapture.Context
    ) async throws -> ScriptedPromptFixture {
        try await ScriptedPromptFixture.make(script: script, label: fixtureLabel, tracer: context.tracer)
    }

    /// Runs `initialize`, `session/new`, one scripted prompt and one
    /// `session/cancel` through the harness inside one capture. The run waits
    /// until the prompt span and the cancel span ended.
    ///
    /// - Returns: The spans and the log records of the run.
    /// - Throws: Whatever the fixture, the wire calls or the waits throw.
    private static func runOnePrompt() async throws -> TracedRun {
        try await TelemetryCapture.run(forbidding: [promptText, answerText]) { context in
            let fixture = try await makeTracedFixture(
                script: [.textDelta(answerText), .endPass], context: context)
            _ = try await fixture.harness.connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: promptText))
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            try await ScriptedPromptFixture.waitForAvailability(fixture.harness.agent, fixture.sessionId)
            try await fixture.harness.connection.sessionCancel(
                CancelSessionNotification(sessionId: fixture.sessionId))
            try await Poll.until("the prompt span and the cancel span ended") {
                let names = Set(context.spans.map(\.operationName))
                return names.isSuperset(of: [ACPAgentTelemetry.SpanName.prompt, ACPAgentTelemetry.SpanName.cancel])
            }
            await fixture.close()
            return TracedRun(sessionId: fixture.sessionId.rawValue, context: context)
        }
    }

    /// Expects one server span with the name `name`, with `method` as its ACP
    /// method.
    ///
    /// - Parameters:
    ///   - name: The span name.
    ///   - method: The ACP method that the span must carry.
    ///   - run: The traced run.
    /// - Returns: The span.
    /// - Throws: When the run holds no span with that name.
    private static func requireOneServerSpan(
        named name: String, method: String, in run: TracedRun
    ) throws -> FinishedInMemorySpan {
        let spans = run.spans(named: name)
        #expect(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.kind == .server)
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.acpMethod) == .string(method))
        return span
    }

    /// One prompt records one server span. The span carries the ACP method,
    /// the session id and the stop reason, and it is the parent of each
    /// Router submission span of the prompt.
    @Test(.timeLimit(.minutes(1)))
    func promptSpanIsTheParentOfEachSubmissionSpanOfThePrompt() async throws {
        let run = try await Self.runOnePrompt()

        let promptSpan = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.prompt, method: Self.sessionPromptMethod, in: run)
        #expect(promptSpan.attributes.get(ACPAgentTelemetry.AttributeKey.sessionId) == .string(run.sessionId))
        #expect(
            promptSpan.attributes.get(ACPAgentTelemetry.AttributeKey.promptStopReason)
                == .string(Self.endTurnStopReason))
        let submissionSpans = run.spans(named: Self.submissionSpanName)
        #expect(!submissionSpans.isEmpty)
        for submissionSpan in submissionSpans {
            #expect(submissionSpan.traceID == promptSpan.traceID)
            #expect(submissionSpan.parentSpanID == promptSpan.spanID)
        }
    }

    /// A prompt writes one "enter" record when it starts.
    @Test(.timeLimit(.minutes(1)))
    func promptWritesOneEnterRecord() async throws {
        let run = try await Self.runOnePrompt()

        #expect(run.enterRecordCount(forSpanNamed: ACPAgentTelemetry.SpanName.prompt) == 1)
    }

    /// `initialize` records one server span with its ACP method.
    @Test(.timeLimit(.minutes(1)))
    func initializeRecordsOneServerSpan() async throws {
        let run = try await Self.runOnePrompt()

        _ = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.initialize, method: Self.initializeMethod, in: run)
    }

    /// `session/new` records one server span with its ACP method and the id
    /// of the new session, and writes one "enter" record when it starts.
    @Test(.timeLimit(.minutes(1)))
    func sessionNewRecordsOneServerSpanAndOneEnterRecord() async throws {
        let run = try await Self.runOnePrompt()

        let span = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.sessionNew, method: Self.sessionNewMethod, in: run)
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.sessionId) == .string(run.sessionId))
        #expect(run.enterRecordCount(forSpanNamed: ACPAgentTelemetry.SpanName.sessionNew) == 1)
    }

    /// `session/cancel` records one server span with its ACP method and the
    /// session id.
    @Test(.timeLimit(.minutes(1)))
    func sessionCancelRecordsOneServerSpan() async throws {
        let run = try await Self.runOnePrompt()

        let span = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.cancel, method: Self.sessionCancelMethod, in: run)
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.sessionId) == .string(run.sessionId))
    }

    /// `session/resume` records one server span with its ACP method, and
    /// writes one "enter" record when it starts. A resume of a session that
    /// no recording holds throws, and the span records the type of the error.
    @Test(.timeLimit(.minutes(1)))
    func sessionResumeRecordsOneServerSpanAndOneEnterRecord() async throws {
        let run = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeTracedFixture(script: [.endPass], context: context)
            await #expect(throws: RequestError.self) {
                _ = try await fixture.harness.connection.resumeSession(
                    ResumeSessionRequest(
                        cwd: AbsolutePath(rawValue: fixture.cwd.path),
                        sessionId: SessionId(rawValue: Self.unrecordedSessionIdValue)))
            }
            await fixture.close()
            return TracedRun(sessionId: Self.unrecordedSessionIdValue, context: context)
        }

        let span = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.sessionResume, method: Self.sessionResumeMethod, in: run)
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.sessionId) == .string(run.sessionId))
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.errorType) == .string(Self.requestErrorTypeName))
        #expect(run.enterRecordCount(forSpanNamed: ACPAgentTelemetry.SpanName.sessionResume) == 1)
    }

    /// A prompt for an unknown session throws. Its span records the error and
    /// the type of the error, and the span ends.
    @Test(.timeLimit(.minutes(1)))
    func promptForAnUnknownSessionRecordsTheErrorOnItsSpan() async throws {
        let run = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeTracedFixture(script: [.endPass], context: context)
            await #expect(throws: RequestError.self) {
                _ = try await fixture.harness.connection.prompt(
                    AgentClientHarness.makePromptRequest(
                        sessionId: SessionId(rawValue: Self.unknownSessionIdValue), text: Self.promptText))
            }
            await fixture.close()
            return TracedRun(sessionId: Self.unknownSessionIdValue, context: context)
        }

        let span = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.prompt, method: Self.sessionPromptMethod, in: run)
        #expect(span.errors.count == 1)
        #expect(span.status?.code == .error)
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.errorType) == .string(Self.requestErrorTypeName))
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.sessionId) == .string(run.sessionId))
    }
}

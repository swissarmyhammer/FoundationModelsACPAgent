import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
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

    /// A session id that no `session/new` gave.
    private static let unknownSessionIdValue = "request-tracing-unknown"

    /// A session id that has the ULID form, and that no recording holds.
    private static let unrecordedSessionIdValue = "01M3MNF3HX2STG00W3GBT21BAS"

    /// The trace id of the remote parent span of the client. It is the
    /// example trace id of the W3C Trace Context specification.
    private static let clientTraceId = "4bf92f3577b34da6a3ce929d0e0e4736"

    /// The span id of the remote parent span of the client. It is the example
    /// parent id of the W3C Trace Context specification.
    private static let clientSpanId = "00f067aa0ba902b7"

    /// The `tracestate` value that the client sends with its `traceparent`.
    private static let clientTracestate = "vendor=client"

    /// A `traceparent` value that holds the ids of the client, with the
    /// version `ff`, which the W3C format forbids.
    private static let forbiddenVersionTraceparent = "ff-\(clientTraceId)-\(clientSpanId)-01"

    /// Makes a request `_meta` object that holds a `traceparent` value and,
    /// when it is not `nil`, a `tracestate` value.
    ///
    /// - Parameters:
    ///   - traceparent: The `traceparent` value.
    ///   - tracestate: The `tracestate` value, or `nil` for none.
    /// - Returns: The `_meta` object.
    private static func makeTraceMeta(traceparent: String, tracestate: String? = nil) -> JSONValue {
        var members: [String: JSONValue] = [TraceContextMeta.traceparentKey: .string(traceparent)]
        members[TraceContextMeta.tracestateKey] = tracestate.map(JSONValue.string)
        return .object(members)
    }

    /// Makes a request `_meta` object that holds the valid `traceparent` of
    /// the remote parent span of the client, and the `tracestate` of the
    /// client.
    ///
    /// - Returns: The `_meta` object.
    /// - Throws: When the ids of the client do not have the W3C format.
    private static func makeClientTraceMeta() throws -> JSONValue {
        let identity = try #require(SpanIdentity(traceID: clientTraceId, spanID: clientSpanId))
        return makeTraceMeta(traceparent: identity.traceparent, tracestate: clientTracestate)
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
    /// - Parameter promptMeta: The `_meta` of the prompt request, or `nil`
    ///   for a request with no `_meta`.
    /// - Returns: The spans and the log records of the run.
    /// - Throws: Whatever the fixture, the wire calls or the waits throw.
    private static func runOnePrompt(promptMeta: JSONValue? = nil) async throws -> TracedRun {
        try await TelemetryCapture.run(forbidding: [promptText, answerText]) { context in
            let fixture = try await makeTracedFixture(
                script: [.textDelta(answerText), .endPass], context: context)
            var request = AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: promptText)
            request.meta = promptMeta
            _ = try await fixture.harness.connection.prompt(request)
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

    /// A prompt writes one "enter" record when it starts. The record carries
    /// the trace id and the span id of the prompt span.
    @Test(.timeLimit(.minutes(1)))
    func promptWritesOneEnterRecordWithTheIdsOfItsSpan() async throws {
        let run = try await Self.runOnePrompt()

        let promptSpan = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.prompt, method: Self.sessionPromptMethod, in: run)
        try run.expectOneEnterRecord(withTheIdsOf: promptSpan)
    }

    /// `initialize` records one server span with its ACP method.
    @Test(.timeLimit(.minutes(1)))
    func initializeRecordsOneServerSpan() async throws {
        let run = try await Self.runOnePrompt()

        _ = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.initialize, method: Self.initializeMethod, in: run)
    }

    /// `session/new` records one server span with its ACP method and the id
    /// of the new session, and writes one "enter" record when it starts. The
    /// record carries the trace id and the span id of the span.
    @Test(.timeLimit(.minutes(1)))
    func sessionNewRecordsOneServerSpanAndOneEnterRecord() async throws {
        let run = try await Self.runOnePrompt()

        let span = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.sessionNew, method: Self.sessionNewMethod, in: run)
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.sessionId) == .string(run.sessionId))
        try run.expectOneEnterRecord(withTheIdsOf: span)
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
    /// writes one "enter" record with the trace id and the span id of the
    /// span when it starts. A resume of a session that no recording holds
    /// throws, and the span records the type of the error.
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
        try run.expectOneEnterRecord(withTheIdsOf: span)
    }

    /// A prompt for an unknown session throws. Its span gets the error status
    /// and the type of the error, and the span ends. The span records no
    /// error, because a tracing backend exports the description of a
    /// recorded error, and a description can hold content.
    @Test(.timeLimit(.minutes(1)))
    func promptForAnUnknownSessionRecordsTheErrorTypeOnItsSpan() async throws {
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
        #expect(span.errors.isEmpty)
        #expect(span.status?.code == .error)
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.errorType) == .string(Self.requestErrorTypeName))
        #expect(span.attributes.get(ACPAgentTelemetry.AttributeKey.sessionId) == .string(run.sessionId))
    }

    /// A prompt whose `_meta` holds a valid `traceparent` records its span in
    /// the trace of the client, as a child of the span of the client. The
    /// span keeps the `tracestate` of the client.
    @Test(.timeLimit(.minutes(1)))
    func promptSpanIsAChildOfTheTraceparentInItsMeta() async throws {
        let run = try await Self.runOnePrompt(promptMeta: Self.makeClientTraceMeta())

        let promptSpan = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.prompt, method: Self.sessionPromptMethod, in: run)
        #expect(promptSpan.traceID == Self.clientTraceId)
        #expect(promptSpan.parentSpanID == Self.clientSpanId)
        #expect(promptSpan.context.w3cTraceState == Self.clientTracestate)
    }

    /// A prompt whose `_meta` holds a `traceparent` that the W3C format does
    /// not allow gets its normal response, and its span starts a new trace.
    @Test(.timeLimit(.minutes(1)))
    func promptWithABadTraceparentStartsANewTrace() async throws {
        let run = try await Self.runOnePrompt(
            promptMeta: Self.makeTraceMeta(traceparent: Self.forbiddenVersionTraceparent))

        let promptSpan = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.prompt, method: Self.sessionPromptMethod, in: run)
        #expect(promptSpan.traceID != Self.clientTraceId)
        #expect(promptSpan.parentSpanID == nil)
        #expect(
            promptSpan.attributes.get(ACPAgentTelemetry.AttributeKey.promptStopReason)
                == .string(Self.endTurnStopReason))
    }

    /// A prompt with no `_meta` records a span that starts a new trace, as
    /// before the agent read the trace context.
    @Test(.timeLimit(.minutes(1)))
    func promptWithNoMetaStartsANewTrace() async throws {
        let run = try await Self.runOnePrompt()

        let promptSpan = try Self.requireOneServerSpan(
            named: ACPAgentTelemetry.SpanName.prompt, method: Self.sessionPromptMethod, in: run)
        #expect(promptSpan.parentSpanID == nil)
    }

    /// `initialize`, `session/new`, `session/resume` and `session/cancel`
    /// each record their span as a child of the `traceparent` in their
    /// `_meta`.
    @Test(.timeLimit(.minutes(1)))
    func eachRequestSpanIsAChildOfTheTraceparentInItsMeta() async throws {
        let meta = try Self.makeClientTraceMeta()
        let run = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeTracedFixture(script: [.endPass], context: context)
            let connection = fixture.harness.connection
            var initializeRequest = AgentClientHarness.makeInitializeRequest()
            initializeRequest.meta = meta
            _ = try await connection.initialize(initializeRequest)
            _ = try await connection.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: fixture.cwd.path), meta: meta))
            await #expect(throws: RequestError.self) {
                _ = try await connection.resumeSession(
                    ResumeSessionRequest(
                        cwd: AbsolutePath(rawValue: fixture.cwd.path),
                        sessionId: SessionId(rawValue: Self.unrecordedSessionIdValue), meta: meta))
            }
            try await connection.sessionCancel(CancelSessionNotification(sessionId: fixture.sessionId, meta: meta))
            try await Poll.until("the cancel span ended") {
                context.spans.contains { $0.operationName == ACPAgentTelemetry.SpanName.cancel }
            }
            await fixture.close()
            return TracedRun(sessionId: fixture.sessionId.rawValue, context: context)
        }

        let spanNames = [
            ACPAgentTelemetry.SpanName.initialize, ACPAgentTelemetry.SpanName.sessionNew,
            ACPAgentTelemetry.SpanName.sessionResume, ACPAgentTelemetry.SpanName.cancel,
        ]
        for name in spanNames {
            let childSpans = run.spans(named: name).filter { span in
                span.traceID == Self.clientTraceId && span.parentSpanID == Self.clientSpanId
            }
            #expect(childSpans.count == 1, "\(name)")
        }
    }
}

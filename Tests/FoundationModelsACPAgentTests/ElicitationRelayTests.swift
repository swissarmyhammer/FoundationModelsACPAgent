import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
@testable import FoundationModelsExtras
@testable import FoundationModelsRouter
import Logging
import MCPTestServer
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The elicitation relay: the wire mapping, the capability
/// gate, and the round trip from `ToolContext.elicit` to the client and
/// back through `RoutedSession.respond`.
struct ElicitationRelayTests {
    // MARK: - Constants

    /// The message of the mapped test requests.
    private static let requestMessage = "What is the answer?"

    /// The one form field of the mapped test requests.
    private static let answerField = "answer"

    /// The link of the mapped URL-mode test requests.
    private static let requestLink = "https://example.com/sign-in"

    /// The tool call id the mapped test requests are scoped to.
    private static let scopedToolCallId = "scoped-call-1"

    /// A well-formed session id for the mapping tests.
    private static let mappedSessionId = SessionId(rawValue: syntheticSessionIdValue)

    // MARK: - Mapping builders

    /// A form-mode Extras request with one required string field.
    ///
    /// - Parameter elicitationId: The id the request carries.
    /// - Returns: The request.
    private static func makeFormRequest(elicitationId: ULID = ULID()) -> ElicitationRequest {
        ElicitationRequest(
            message: requestMessage,
            elicitationId: elicitationId,
            requestedSchema: ElicitationRequestedSchema(
                properties: [answerField: .string(ElicitationStringSchema())],
                required: [answerField]))
    }

    /// A URL-mode Extras request.
    ///
    /// - Parameter elicitationId: The id the request carries.
    /// - Returns: The request.
    /// - Throws: When ``requestLink`` does not parse as a URL.
    private static func makeURLRequest(elicitationId: ULID = ULID()) throws -> ElicitationRequest {
        ElicitationRequest(
            message: requestMessage,
            elicitationId: elicitationId,
            url: try #require(URL(string: requestLink)))
    }

    // MARK: - The request mapping

    /// A form-mode request maps to a form-mode create: the message, the
    /// schema fields, and the session scope with the run's tool call id.
    @Test func aFormRequestMapsToAFormModeCreateScopedToTheSessionAndToolCall() throws {
        let request = Self.makeFormRequest()

        let wire = try #require(
            ElicitationRelay.wireRequest(
                for: request, sessionId: Self.mappedSessionId, toolCallId: Self.scopedToolCallId))

        #expect(wire.message == Self.requestMessage)
        if case .form(let form) = wire.mode {
            #expect(form.requestedSchema.required == [Self.answerField])
            if case .object(let properties) = form.requestedSchema.properties {
                #expect(properties.keys.contains(Self.answerField))
            } else {
                Issue.record("expected an object of properties, got \(form.requestedSchema.properties)")
            }
            if case .session(let scope) = form.scope {
                #expect(scope.sessionId == Self.mappedSessionId)
                #expect(scope.toolCallId == ToolCallId(rawValue: Self.scopedToolCallId))
            } else {
                Issue.record("expected a session scope, got \(form.scope)")
            }
        } else {
            Issue.record("expected a form mode, got \(wire.mode)")
        }
    }

    /// A URL-mode request maps to a URL-mode create that carries the
    /// request's own elicitation id and the link.
    @Test func aURLRequestMapsToAURLModeCreateCarryingTheElicitationId() throws {
        let elicitationId = ULID()
        let request = try Self.makeURLRequest(elicitationId: elicitationId)

        let wire = try #require(
            ElicitationRelay.wireRequest(
                for: request, sessionId: Self.mappedSessionId, toolCallId: Self.scopedToolCallId))

        #expect(wire.message == Self.requestMessage)
        if case .url(let urlMode) = wire.mode {
            #expect(urlMode.elicitationId == ElicitationId(rawValue: elicitationId.ulidString))
            #expect(urlMode.url == Self.requestLink)
            if case .session(let scope) = urlMode.scope {
                #expect(scope.sessionId == Self.mappedSessionId)
                #expect(scope.toolCallId == ToolCallId(rawValue: Self.scopedToolCallId))
            } else {
                Issue.record("expected a session scope, got \(urlMode.scope)")
            }
        } else {
            Issue.record("expected a url mode, got \(wire.mode)")
        }
    }

    // MARK: - The answer decoding

    /// The three wire actions decode to the three Extras actions, and a
    /// form-mode accept keeps its content.
    @Test func theClientAnswerDecodesAcceptDeclineAndCancel() {
        let accept = ElicitationRelay.answer(
            from: .object([
                "action": .string("accept"),
                "content": .object([Self.answerField: .string("blue")]),
            ]),
            mode: .form)
        #expect(accept == .accept(content: [Self.answerField: .string("blue")]))

        let decline = ElicitationRelay.answer(from: .object(["action": .string("decline")]), mode: .form)
        #expect(decline == .decline)

        let cancel = ElicitationRelay.answer(from: .object(["action": .string("cancel")]), mode: .form)
        #expect(cancel == .cancel)
    }

    /// An accept with no content decodes to an accept with `nil` content.
    @Test func anAcceptWithoutContentDecodesToAnEmptyAccept() {
        let accept = ElicitationRelay.answer(from: .object(["action": .string("accept")]), mode: .form)
        #expect(accept == .accept(content: nil))
    }

    /// A URL-mode accept never carries content back over ACP: the flow
    /// returns its data out of band. This is a security duty of the agent:
    /// URL-mode credentials must not come back over ACP.
    @Test func aURLModeAcceptNeverCarriesContentBack() {
        let accept = ElicitationRelay.answer(
            from: .object([
                "action": .string("accept"),
                "content": .object([Self.answerField: .string("secret")]),
            ]),
            mode: .url)
        #expect(accept == .accept(content: nil))
    }

    /// An answer this relay cannot read delivers `cancel`, never a guess:
    /// a missing answer, an unknown action, and undecodable content.
    @Test func anUnreadableAnswerBecomesCancel() {
        #expect(ElicitationRelay.answer(from: nil, mode: .form) == .cancel)
        #expect(
            ElicitationRelay.answer(from: .object(["action": .string("later")]), mode: .form)
                == .cancel)
        #expect(
            ElicitationRelay.answer(
                from: .object([
                    "action": .string("accept"),
                    "content": .object([Self.answerField: .object([:])]),
                ]),
                mode: .form) == .cancel)
    }

    // MARK: - The harness wiring

    /// The name the eliciting MCP test server mounts under.
    private static let serverName = "elicitor"

    /// The prompt text of every scripted elicitation case.
    private static let promptText = "Run the eliciting tool pass"

    /// The form value the accepting tests send.
    private static let acceptedAnswer = "blue"

    /// The text the eliciting loopback tools reflect for an accept.
    private static let acceptedResultText = "elicitation accept"

    /// The text the eliciting loopback tools reflect for a decline.
    private static let declinedResultText = "elicitation decline"

    /// The text the eliciting loopback tools reflect for a cancel.
    private static let cancelledResultText = "elicitation cancel"

    /// The snippet that runs the form-mode eliciting loopback tool.
    private static let formSnippet =
        "return await tools.\(serverName).\(ScriptedServer.elicitEchoToolName)({});"

    /// The snippet that runs the URL-mode eliciting loopback tool.
    private static let urlSnippet =
        "return await tools.\(serverName).\(ScriptedServer.elicitURLToolName)({});"

    /// Client capabilities that advertise form-mode elicitation only.
    private static let formOnlyCapabilities = ClientCapabilities(
        elicitation: ElicitationCapabilities(form: ElicitationFormCapabilities()))

    /// The state markers of the collected sequence, in arrival order.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The markers of the running, requires-action, and idle
    ///   state updates. The agent sends no requires-action; the marker
    ///   shows a defect.
    private static func stateMarkers(in updates: [UpdateSessionNotification]) -> [String] {
        updates.compactMap { notification in
            switch notification.update {
            case .stateUpdate(.running): "running"
            case .stateUpdate(.requiresAction): "requires_action"
            case .stateUpdate(.idle): "idle"
            default: nil
            }
        }
    }

    /// Wires a fixture whose session mounts the loopback `mcp-test-server`
    /// and whose scripted model runs `code` in one tool pass.
    ///
    /// - Parameters:
    ///   - code: The snippet the pass runs.
    ///   - capabilities: The client capabilities `initialize` announces.
    ///   - label: The directory label of the calling test.
    /// - Returns: The fixture.
    /// - Throws: Whatever the wiring throws.
    private static func makeLoopbackFixture(
        code: String,
        capabilities: ClientCapabilities = ACPClient.advertisedCapabilities,
        label: String
    ) async throws -> ScriptedPromptFixture {
        let serverCommand = try BuiltProductLocator.mcpTestServerURL().path
        let server = FoundationModelsACP.MCPServer.stdio(
            MCPServerStdio(
                command: AbsolutePath(rawValue: serverCommand),
                name: serverName,
                args: [ServerMode.flagName, ServerMode.loopback.rawValue]))
        return try await ScriptedPromptFixture.make(
            script: ScriptedPromptFixture.makeToolPromptScript(code: code, onPromptContaining: promptText),
            label: label,
            capabilities: capabilities,
            mcpServers: [server])
    }

    /// Prompts the fixture's one session with the shared prompt text.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Throws: Whatever the prompt request throws.
    private static func prompt(_ fixture: ScriptedPromptFixture) async throws {
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: promptText))
    }

    // MARK: - The form round trip

    /// A tool that elicits in form mode produces one `elicitation/create`
    /// at the client, and the tool receives the accepted content. The answer
    /// of the prompt is Router work while its tool waits, so the session
    /// stays `running`: no `requires_action` goes out.
    @Test
    func aFormElicitationRoundTripsTheAcceptedContentToTheTool() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.formSnippet, label: "ElicitationRelayTests-form-accept")
        try await Self.prompt(fixture)

        let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
        #expect(pending.request.message == ScriptedServer.elicitEchoMessage)
        if case .form(let form) = pending.request.mode {
            #expect(form.requestedSchema.required == [ScriptedServer.elicitEchoAnswerField])
            if case .session(let scope) = form.scope {
                #expect(scope.sessionId == fixture.sessionId)
                #expect(scope.toolCallId != nil)
            } else {
                Issue.record("expected a session scope, got \(form.scope)")
            }
        } else {
            Issue.record("expected a form mode, got \(pending.request.mode)")
        }
        let markersAtPending = Self.stateMarkers(in: await fixture.collector.updates)
        #expect(markersAtPending == ["running"])

        await MainActor.run {
            fixture.session.acceptElicitation(
                pending.id,
                content: .object([
                    ScriptedServer.elicitEchoAnswerField: .string(Self.acceptedAnswer)
                ]))
        }
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        let creates = await Self.recordedCreates(of: fixture)
        await fixture.close()

        #expect(creates.count == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
        #expect(Self.stateMarkers(in: updates) == ["running", "idle"])
        let wireText = try encodedWireText(of: updates)
        #expect(wireText.contains(Self.acceptedAnswer))
        #expect(wireText.contains(Self.acceptedResultText))
    }

    /// A declined form elicitation reaches the tool as `decline`, and the
    /// prompt still ends `end_turn`.
    @Test
    func aDeclinedFormElicitationReachesTheToolAsDecline() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.formSnippet, label: "ElicitationRelayTests-form-decline")
        try await Self.prompt(fixture)
        let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)

        await MainActor.run {
            fixture.session.declineElicitation(pending.id)
        }
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        let creates = await Self.recordedCreates(of: fixture)
        await fixture.close()

        #expect(creates.count == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
        #expect(try encodedWireText(of: updates).contains(Self.declinedResultText))
    }

    // MARK: - The capability gate

    /// A client with no `elicitation` capability gets a headless session
    /// (elicitation-plan task 7): Extras answers the question at once with
    /// cancel and the reason "no user is present", so no
    /// `elicitation/create` is sent, the relay does not decline, and the
    /// tool receives `cancel`.
    @Test
    func aClientWithoutTheCapabilityIsHeadlessAndTheToolGetsCancel() async throws {
        let captured = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeLoopbackFixture(
                code: Self.formSnippet,
                capabilities: ClientCapabilities(),
                label: "ElicitationRelayTests-no-capability")
            try await Self.prompt(fixture)

            let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            let creates = await Self.recordedCreates(of: fixture)
            await fixture.close()
            return (updates: updates, creates: creates, records: context.logRecords)
        }

        #expect(captured.creates.isEmpty)
        #expect(ScriptedPromptFixture.idleStopReason(in: captured.updates) == .endTurn)
        #expect(!Self.stateMarkers(in: captured.updates).contains("requires_action"))
        #expect(try encodedWireText(of: captured.updates).contains(Self.cancelledResultText))
        #expect(
            !captured.records.contains {
                $0.metadata[ACPAgentTelemetry.LogMetadataKey.elicitationDeclineReason] != nil
            })
    }

    /// A client with `form` only, asked in `url` mode, receives nothing —
    /// the relay never falls back to form — and the tool receives
    /// `decline`.
    @Test
    func aFormOnlyClientAskedInURLModeReceivesNothingAndTheToolReceivesDecline() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.urlSnippet,
            capabilities: Self.formOnlyCapabilities,
            label: "ElicitationRelayTests-form-only-url")
        try await Self.prompt(fixture)

        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        let creates = await Self.recordedCreates(of: fixture)
        await fixture.close()

        #expect(creates.isEmpty)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
        #expect(!Self.stateMarkers(in: updates).contains("requires_action"))
        #expect(try encodedWireText(of: updates).contains(Self.declinedResultText))
    }

    // MARK: - The decline log record

    /// The label of each logger of the elicitation relay.
    private static let elicitationRelayLoggerLabel = "FoundationModelsACPAgent.ElicitationRelay"

    /// A decline of a URL-mode request to a client with `form` only writes
    /// one `notice` record. The mode, the decline reason and the session id
    /// are in the metadata of the record.
    @Test
    func aDeclineForAnUnsupportedModeWritesOneNoticeWithTheModeInMetadata() async throws {
        let modeKey = ACPAgentTelemetry.LogMetadataKey.elicitationMode
        let captured = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeLoopbackFixture(
                code: Self.urlSnippet,
                capabilities: Self.formOnlyCapabilities,
                label: "ElicitationRelayTests-decline-record")
            try await Self.prompt(fixture)
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            await fixture.close()
            return (sessionId: fixture.sessionId.rawValue, records: context.logRecords)
        }

        let declineRecords = captured.records.filter { $0.metadata[modeKey] == .string("url") }
        #expect(declineRecords.count == 1)
        let record = try #require(declineRecords.first)
        #expect(record.level == .notice)
        #expect(
            record.metadata[ACPAgentTelemetry.LogMetadataKey.elicitationDeclineReason]
                == .string("unsupportedMode"))
        #expect(
            record.metadata[ACPAgentTelemetry.LogMetadataKey.sessionId] == .string(captured.sessionId))
    }

    /// Each decline of the relay goes to Router as `decline` with the raw
    /// value of its reason, so the tool and the model see why.
    @Test(arguments: [
        ElicitationRelay.DeclineReason.unsupportedMode,
        .missingPayload,
        .duplicateURLElicitationId,
    ])
    func eachDeclineOfTheRelayCarriesItsReason(_ reason: ElicitationRelay.DeclineReason) {
        let response = ElicitationRelay.declineResponse(for: reason)

        #expect(response == .decline(reason: reason.rawValue))
        #expect(response.action == .decline)
    }

    /// Relays `request` straight to the relay of the fixture's session, over
    /// a double of the Router session that records each answer.
    ///
    /// - Parameters:
    ///   - request: The request to relay.
    ///   - fixture: The wired fixture.
    ///   - session: The double that records the answers.
    /// - Throws: When the session or its relay is missing.
    private static func relayDirectly(
        _ request: ElicitationRequest, in fixture: ScriptedPromptFixture, over session: CloseCountingRoutedSession
    ) async throws {
        let relay = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.projector.relay)
        let event = OperationEvent(
            tool: serverName, op: "elicit", correlationID: "relay-direct", kind: .elicitation, detail: "",
            elicitation: request)
        await relay.relay(event, on: session)
    }

    /// The double of the fixture's Router session that records each answer.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The double.
    /// - Throws: When the session is missing.
    private static func recordingSession(of fixture: ScriptedPromptFixture) async throws -> CloseCountingRoutedSession {
        CloseCountingRoutedSession(
            wrapping: try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session))
    }

    /// A URL-mode request to a client with `form` only reaches Router as
    /// `decline` with the reason `unsupportedMode`.
    @Test
    func anUnsupportedModeDeclineReachesRouterWithItsReason() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.formSnippet,
            capabilities: Self.formOnlyCapabilities,
            label: "ElicitationRelayTests-decline-unsupported")
        let session = try await Self.recordingSession(of: fixture)

        try await Self.relayDirectly(try Self.makeURLRequest(), in: fixture, over: session)
        let responses = await session.responses.map(\.response)
        await fixture.close()

        #expect(responses == [.decline(reason: ElicitationRelay.DeclineReason.unsupportedMode.rawValue)])
    }

    /// A second URL-mode request with the id of an outstanding URL
    /// elicitation reaches Router as `decline` with the reason
    /// `duplicateURLElicitationId`, and sends no second create.
    @Test
    func aDuplicateURLElicitationIdDeclineReachesRouterWithItsReason() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.formSnippet, label: "ElicitationRelayTests-decline-duplicate")
        let session = try await Self.recordingSession(of: fixture)
        let elicitationId = ULID()
        let first = Task {
            try await Self.relayDirectly(
                try Self.makeURLRequest(elicitationId: elicitationId), in: fixture, over: session)
        }
        let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)

        try await Self.relayDirectly(
            try Self.makeURLRequest(elicitationId: elicitationId), in: fixture, over: session)
        let responsesAtDuplicate = await session.responses.map(\.response)
        await MainActor.run {
            fixture.session.cancelElicitation(pending.id)
        }
        try await first.value
        let creates = await Self.recordedCreates(of: fixture).count
        await fixture.close()

        #expect(
            responsesAtDuplicate
                == [.decline(reason: ElicitationRelay.DeclineReason.duplicateURLElicitationId.rawValue)])
        #expect(creates == 1)
    }

    /// The logger of the elicitation relay has the module label and the
    /// category of the elicitation relay.
    @Test func elicitationRelayLoggerHasTheModuleLabel() {
        #expect(
            ACPAgentTelemetry.logger(.elicitationRelay).label == Self.elicitationRelayLoggerLabel)
    }

    // MARK: - The URL round trip

    /// Waits until the elicitation span of the relay ended. The span ends
    /// after Router recorded the answer of the client, and after the relay
    /// keeps an accepted URL flow as awaiting completion. Thus a test that
    /// accepts a URL question uses this end as its fixed point after the
    /// accept.
    ///
    /// - Parameter context: The telemetry capture of the test.
    private static func waitForTheEndOfTheElicitationSpan(in context: TelemetryCapture.Context) async {
        await context.wait { captured in
            captured.spans.contains { $0.operationName == ACPAgentTelemetry.SpanName.elicitation }
        }
    }

    /// The elicitation ids of the `elicitation/complete` notifications that
    /// reached the client of the fixture.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The ids, in arrival order.
    /// - Throws: When the fixture has no elicitation recorder.
    private static func recordedCompletions(of fixture: ScriptedPromptFixture) async throws -> [ElicitationId] {
        await (try #require(fixture.harness.elicitations)).completions.map(\.elicitationId)
    }

    /// The completion token of the run that asked the URL-mode question
    /// `pending`: the tool call id of its session scope.
    ///
    /// - Parameter pending: The pending URL-mode question at the client.
    /// - Returns: The completion token.
    /// - Throws: When the question is not a URL-mode question scoped to a
    ///   tool call.
    private static func runToken(ofURLQuestion pending: PendingElicitation) throws -> String {
        guard case .url(let urlMode) = pending.request.mode, case .session(let scope) = urlMode.scope,
            let toolCallId = scope.toolCallId
        else {
            throw URLQuestionNotScoped(mode: "\(pending.request.mode)")
        }
        return toolCallId.rawValue
    }

    /// A URL-mode question at the client that is not scoped to a tool call.
    private struct URLQuestionNotScoped: Error {
        /// The mode of the question, for the failure message.
        let mode: String
    }

    /// URL mode: an accept does not end the flow (task ^az53ay4). After the
    /// accept no `elicitation/complete` goes out. The out-of-band flow then
    /// completes on the run plane, and Router sends
    /// `elicitationCompleted`: then one `elicitation/complete` reaches the
    /// client, and the tool resumes with the accept.
    @Test
    func aURLElicitationCompletesOnlyWhenItsFlowCompletesAndNotAtTheAccept() async throws {
        let captured = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeLoopbackFixture(
                code: Self.urlSnippet, label: "ElicitationRelayTests-url-accept")
            try await Self.prompt(fixture)

            let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
            #expect(pending.request.message == ScriptedServer.elicitURLMessage)
            #expect(pending.url?.absoluteString == ScriptedServer.elicitURLLink)
            let elicitationId = try #require(pending.elicitationId)

            await MainActor.run {
                fixture.session.acceptElicitation(pending.id)
            }
            await Self.waitForTheEndOfTheElicitationSpan(in: context)
            let completionsAtAccept = try await Self.recordedCompletions(of: fixture)

            let actor = try await Self.sessionActor(of: fixture)
            let questionId = try #require(ULID(ulidString: elicitationId.rawValue))
            let delivery = await actor.runPlane.complete(elicitationId: questionId)
            let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            let completions = try await Self.recordedCompletions(of: fixture)
            await fixture.close()
            return (
                elicitationId: elicitationId, completionsAtAccept: completionsAtAccept, delivery: delivery,
                completions: completions, updates: updates)
        }

        #expect(captured.completionsAtAccept.isEmpty)
        #expect(captured.delivery == .completed)
        #expect(captured.completions == [captured.elicitationId])
        #expect(ScriptedPromptFixture.idleStopReason(in: captured.updates) == .endTurn)
        #expect(Self.stateMarkers(in: captured.updates) == ["running", "idle"])
        #expect(try encodedWireText(of: captured.updates).contains(Self.acceptedResultText))
    }

    /// URL mode: a cancel of the run after the accept ends the flow. Router
    /// sends `elicitationEnded` for the accepted question, and the relay
    /// sends one `elicitation/complete`, so the client leaves its waiting
    /// state. No `elicitation/complete` goes out at the accept.
    @Test
    func aRunCancelAfterAURLAcceptSendsOneCompletion() async throws {
        let captured = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeLoopbackFixture(
                code: Self.urlSnippet, label: "ElicitationRelayTests-url-accept-run-cancel")
            try await Self.prompt(fixture)

            let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
            let elicitationId = try #require(pending.elicitationId)
            let runToken = try Self.runToken(ofURLQuestion: pending)

            await MainActor.run {
                fixture.session.acceptElicitation(pending.id)
            }
            await Self.waitForTheEndOfTheElicitationSpan(in: context)
            let completionsAtAccept = try await Self.recordedCompletions(of: fixture)

            let actor = try await Self.sessionActor(of: fixture)
            _ = await actor.runPlane.cancel(completionToken: runToken)
            let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            let completions = try await Self.recordedCompletions(of: fixture)
            await fixture.close()
            return (
                elicitationId: elicitationId, completionsAtAccept: completionsAtAccept,
                completions: completions, updates: updates)
        }

        #expect(captured.completionsAtAccept.isEmpty)
        #expect(captured.completions == [captured.elicitationId])
        #expect(!Self.stateMarkers(in: captured.updates).contains("requires_action"))
    }

    // MARK: - A URL flow that ends while the relay waits for respond

    /// The two gates of a hold of the relay after `session.respond`: the
    /// hold opens `reached` when it starts, and waits until the test opens
    /// `release`.
    private struct RespondHold {
        /// Open when the relay holds after `session.respond`.
        let reached = LateAnswerGate()

        /// The test opens it to end the hold.
        let release = LateAnswerGate()
    }

    /// Holds the relay of the fixture's session after each
    /// `session.respond` (task ^t2sen06).
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The gates of the hold.
    /// - Throws: When the session or its relay is missing.
    private static func holdRelayAfterRespond(of fixture: ScriptedPromptFixture) async throws -> RespondHold {
        let relay = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.projector.relay)
        let hold = RespondHold()
        await relay.holdAfterRespond { _ in
            await hold.reached.open()
            await hold.release.wait()
        }
        return hold
    }

    /// Waits until the relay wrote a log record with `message`.
    ///
    /// - Parameters:
    ///   - message: The message of the record.
    ///   - context: The telemetry capture of the test.
    private static func waitForRecord(_ message: String, in context: TelemetryCapture.Context) async {
        await context.wait { captured in
            captured.logRecords.contains { $0.message.description == message }
        }
    }

    /// Sends one marker update through the inbox of the fixture's session,
    /// and waits until the client has it. The client reads notifications
    /// one at a time, in arrival order. Thus when the marker is there, each
    /// notification that the agent sent before it is there too.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Throws: When the session is missing, or the test is cancelled.
    private static func sendMarkerAndWait(through fixture: ScriptedPromptFixture) async throws {
        let marker = "relay-order-marker"
        let projector = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.projector)
        await projector.commandSink(.sessionInfoUpdate(SessionInfoUpdate(title: .value(marker))))
        _ = try await ScriptedPromptFixture.waitForUpdates(of: fixture.collector, toReach: "the marker update") {
            updates in
            updates.contains { notification in
                if case .sessionInfoUpdate(let info) = notification.update, info.title == .value(marker) {
                    return true
                }
                return false
            }
        }
    }

    /// The record of the relay for a completion that comes before the
    /// round trip knows of the accept.
    private static let earlyCompletionRecord =
        "A URL flow completed before the relay knew of the accept. The relay keeps the completion."

    /// The record of the relay for an end that comes when no client request
    /// is in flight.
    private static let earlyEndRecord =
        "Router ended a question that has no client request in flight. The relay keeps the end."

    /// URL mode: the flow completes while the relay waits for `respond`
    /// (task ^t2sen06). The relay keeps the completion, and sends no
    /// `elicitation/complete` yet. When the round trip reads the accept,
    /// the relay sends one `elicitation/complete`.
    @Test
    func aURLCompletionWhileTheRelayWaitsForRespondSendsOneCompletionAfterTheAccept() async throws {
        let captured = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeLoopbackFixture(
                code: Self.urlSnippet, label: "ElicitationRelayTests-url-early-completion")
            let hold = try await Self.holdRelayAfterRespond(of: fixture)
            try await Self.prompt(fixture)
            let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
            let elicitationId = try #require(pending.elicitationId)

            await MainActor.run {
                fixture.session.acceptElicitation(pending.id)
            }
            await hold.reached.wait()
            let actor = try await Self.sessionActor(of: fixture)
            let questionId = try #require(ULID(ulidString: elicitationId.rawValue))
            let delivery = await actor.runPlane.complete(elicitationId: questionId)
            await Self.waitForRecord(Self.earlyCompletionRecord, in: context)
            let completionsInHold = try await Self.recordedCompletions(of: fixture)

            await hold.release.open()
            await Self.waitForTheEndOfTheElicitationSpan(in: context)
            try await Self.sendMarkerAndWait(through: fixture)
            let completions = try await Self.recordedCompletions(of: fixture)
            let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            await fixture.close()
            return (
                elicitationId: elicitationId, delivery: delivery, completionsInHold: completionsInHold,
                completions: completions, updates: updates)
        }

        #expect(captured.delivery == .completed)
        #expect(captured.completionsInHold.isEmpty)
        #expect(captured.completions == [captured.elicitationId])
        #expect(ScriptedPromptFixture.idleStopReason(in: captured.updates) == .endTurn)
    }

    /// URL mode: a cancel of the run ends the accepted flow while the relay
    /// waits for `respond` (task ^t2sen06). The relay keeps the end, and
    /// sends no `elicitation/complete` yet. When the round trip reads the
    /// accept, the relay sends one `elicitation/complete`, so the client
    /// leaves its waiting state.
    @Test
    func aRunCancelWhileTheRelayWaitsForRespondSendsOneCompletionAfterTheAccept() async throws {
        let captured = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeLoopbackFixture(
                code: Self.urlSnippet, label: "ElicitationRelayTests-url-early-end")
            let hold = try await Self.holdRelayAfterRespond(of: fixture)
            try await Self.prompt(fixture)
            let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
            let elicitationId = try #require(pending.elicitationId)
            let runToken = try Self.runToken(ofURLQuestion: pending)

            await MainActor.run {
                fixture.session.acceptElicitation(pending.id)
            }
            await hold.reached.wait()
            let actor = try await Self.sessionActor(of: fixture)
            _ = await actor.runPlane.cancel(completionToken: runToken)
            await Self.waitForRecord(Self.earlyEndRecord, in: context)
            let completionsInHold = try await Self.recordedCompletions(of: fixture)

            await hold.release.open()
            await Self.waitForTheEndOfTheElicitationSpan(in: context)
            try await Self.sendMarkerAndWait(through: fixture)
            let completions = try await Self.recordedCompletions(of: fixture)
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            await fixture.close()
            return (elicitationId: elicitationId, completionsInHold: completionsInHold, completions: completions)
        }

        #expect(captured.completionsInHold.isEmpty)
        #expect(captured.completions == [captured.elicitationId])
    }

    // MARK: - Cancellation

    /// `session/cancel` during a pending elicitation ends the prompt with
    /// `idle(cancelled)` and ends the question. The `cancelAll()` signal of
    /// Router first sends the terminal event of the prompt's mail, and then
    /// ends the question with `cancel` and the reason "run cancelled", and
    /// the relay ends the client request. The states are `running` and one
    /// `idle`, with no `requires_action`. The URL-mode tool is used here, so
    /// the cancel also releases an outstanding URL elicitation id.
    @Test
    func sessionCancelDuringAPendingElicitationDeliversCancelBeforeIdle() async throws {
        let captured = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeLoopbackFixture(
                code: Self.urlSnippet, label: "ElicitationRelayTests-cancel")
            try await Self.prompt(fixture)
            _ = try await ElicitationWait.firstPendingElicitation(in: fixture.session)

            try await fixture.harness.connection.sessionCancel(
                CancelSessionNotification(sessionId: fixture.sessionId))
            let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            await fixture.close()
            return (updates: updates, records: context.logRecords)
        }

        #expect(ScriptedPromptFixture.idleStopReason(in: captured.updates) == .cancelled)
        #expect(Self.stateMarkers(in: captured.updates) == ["running", "idle"])
        let ends = Self.endRecords(in: captured.records)
        #expect(ends.count == 1)
        #expect(
            ends.first?.metadata[ACPAgentTelemetry.LogMetadataKey.elicitationEndReason]
                == .string(RunPlane.runCancelledReason))
    }

    /// The records of the relay for a question that Router ended: the
    /// records whose metadata has the end reason.
    ///
    /// - Parameter records: The captured log records.
    /// - Returns: The end records, in order.
    private static func endRecords(in records: [TelemetryCapture.LogRecord]) -> [TelemetryCapture.LogRecord] {
        records.filter { $0.metadata[ACPAgentTelemetry.LogMetadataKey.elicitationEndReason] != nil }
    }

    /// The Router session actor of the fixture's one session, so a test can
    /// cancel one run on its run plane.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The session actor.
    /// - Throws: When the session is missing or is not the Router actor.
    private static func sessionActor(of fixture: ScriptedPromptFixture) async throws -> RoutedSessionActor {
        let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
        return try #require(session as? RoutedSessionActor)
    }

    /// A cancel of the run of a question while the client request is open
    /// ends that client request (gap ^crjmk34). Router ends the question
    /// with `cancel` and the reason "run cancelled", before the run
    /// settles. The relay ends the client request before the projector reads
    /// the settlement, thus its record is there when the prompt is idle. Then
    /// the client request ends at the client: `$/cancel_request` goes out
    /// on its own task, so the test waits for that end.
    @Test
    func aCancelOfTheRunEndsTheOpenClientRequestWithTheRunCancelledReason() async throws {
        let captured = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeLoopbackFixture(
                code: Self.formSnippet, label: "ElicitationRelayTests-run-cancel")
            try await Self.prompt(fixture)
            let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
            guard case .form(let form) = pending.request.mode, case .session(let scope) = form.scope,
                let toolCallId = scope.toolCallId
            else {
                Issue.record("expected a form request scoped to a tool call, got \(pending.request.mode)")
                await fixture.close()
                return (records: context.logRecords, creates: 0)
            }

            let actor = try await Self.sessionActor(of: fixture)
            _ = await actor.runPlane.cancel(completionToken: toolCallId.rawValue)
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            let endsAtIdle = Self.endRecords(in: context.logRecords)
            try #require(endsAtIdle.count == 1, "the relay did not end the client request: \(endsAtIdle)")
            try await ElicitationWait.waitUntilNoPendingElicitation(in: fixture.session)
            let creates = await Self.recordedCreates(of: fixture).count
            await fixture.close()
            return (records: context.logRecords, creates: creates)
        }

        #expect(captured.creates == 1)
        let record = try #require(Self.endRecords(in: captured.records).first)
        #expect(record.level == .notice)
        #expect(
            record.metadata[ACPAgentTelemetry.LogMetadataKey.elicitationEndReason]
                == .string(RunPlane.runCancelledReason))
        #expect(record.metadata[ACPAgentTelemetry.LogMetadataKey.elicitationOutcome] == .string("cancel"))
    }

    /// A question that the client answered gets no end: Router sends
    /// `elicitationEnded` only for a question that ended with no answer of
    /// the client, so the relay writes no end record.
    @Test
    func anAnsweredQuestionGetsNoEnd() async throws {
        let records = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeLoopbackFixture(
                code: Self.formSnippet, label: "ElicitationRelayTests-answered-no-end")
            try await Self.prompt(fixture)
            let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
            await MainActor.run {
                fixture.session.acceptElicitation(
                    pending.id,
                    content: .object([
                        ScriptedServer.elicitEchoAnswerField: .string(Self.acceptedAnswer)
                    ]))
            }
            _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
            await fixture.close()
            return context.logRecords
        }

        #expect(Self.endRecords(in: records).isEmpty)
    }

    /// The recorded `elicitation/create` requests of the fixture.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The recorded requests, in arrival order.
    private static func recordedCreates(
        of fixture: ScriptedPromptFixture
    ) async -> [CreateElicitationRequest] {
        await fixture.harness.elicitations?.creates ?? []
    }
}

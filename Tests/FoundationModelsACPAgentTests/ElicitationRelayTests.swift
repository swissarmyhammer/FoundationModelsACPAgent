import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import FoundationModelsExtras
import FoundationModelsRouter
import MCPTestServer
import Testing

@testable import FoundationModelsACPAgent

/// The elicitation relay (plan.md §16): the wire mapping, the capability
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
    /// returns its data out of band (plan.md §16, the security duty).
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

    // MARK: - The harness wiring (plan.md §20.1)

    /// The name the eliciting MCP test server mounts under.
    private static let serverName = "elicitor"

    /// The prompt of every scripted elicitation turn.
    private static let promptText = "Run the eliciting tool turn"

    /// The form value the accepting tests send.
    private static let acceptedAnswer = "blue"

    /// The text the eliciting loopback tools reflect for an accept.
    private static let acceptedResultText = "elicitation accept"

    /// The text the eliciting loopback tools reflect for a decline.
    private static let declinedResultText = "elicitation decline"

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
    ///   state updates.
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
    /// and whose scripted model runs `code` in one tool turn.
    ///
    /// - Parameters:
    ///   - code: The snippet the turn runs.
    ///   - capabilities: The client capabilities `initialize` announces.
    ///   - label: The directory label of the calling test.
    /// - Returns: The fixture.
    /// - Throws: Whatever the wiring throws.
    private static func makeLoopbackFixture(
        code: String,
        capabilities: ClientCapabilities = ACPClient.advertisedCapabilities,
        label: String
    ) async throws -> ScriptedTurnFixture {
        let serverCommand = try BuiltProductLocator.mcpTestServerURL().path
        let server = FoundationModelsACP.MCPServer.stdio(
            MCPServerStdio(
                command: try #require(AbsolutePath(rawValue: serverCommand)),
                name: serverName,
                args: [ServerMode.flagName, ServerMode.loopback.rawValue]))
        return try await ScriptedTurnFixture.make(
            script: ScriptedTurnFixture.makeToolTurnScript(code: code),
            label: label,
            capabilities: capabilities,
            mcpServers: [server])
    }

    /// Prompts the fixture's one session with the shared prompt text.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Throws: Whatever the prompt request throws.
    private static func prompt(_ fixture: ScriptedTurnFixture) async throws {
        _ = try await fixture.harness.connection.prompt(
            ScriptedTurnFixture.makePromptRequest(sessionId: fixture.sessionId, text: promptText))
    }

    /// Polls the client until the session holds a pending elicitation.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The first pending elicitation.
    /// - Throws: When no elicitation reaches the client in time.
    private static func waitForPendingElicitation(
        in fixture: ScriptedTurnFixture
    ) async throws -> PendingElicitation {
        for _ in 0..<ScriptedTurnFixture.maxPollAttempts {
            let pending = await MainActor.run {
                fixture.harness.client.pendingElicitations(for: fixture.sessionId)
            }
            if let first = pending.first {
                return first
            }
            try await Task.sleep(for: ScriptedTurnFixture.pollInterval)
        }
        return try #require(
            await MainActor.run {
                fixture.harness.client.pendingElicitations(for: fixture.sessionId)
            }.first)
    }

    // MARK: - The form round trip

    /// A tool that elicits in form mode produces one `elicitation/create`
    /// at the client, `requires_action` before it and `running` after the
    /// answer, and the tool receives the accepted content.
    @Test(.timeLimit(.minutes(1)))
    func aFormElicitationRoundTripsTheAcceptedContentToTheTool() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.formSnippet, label: "ElicitationRelayTests-form-accept")
        try await Self.prompt(fixture)

        let pending = try await Self.waitForPendingElicitation(in: fixture)
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
        #expect(markersAtPending.last == "requires_action")

        await MainActor.run {
            fixture.harness.client.acceptElicitation(
                pending.id,
                content: .object([
                    ScriptedServer.elicitEchoAnswerField: .string(Self.acceptedAnswer)
                ]))
        }
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        let creates = await Self.recordedCreates(of: fixture)
        await fixture.close()

        #expect(creates.count == 1)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
        expectOrderedSubsequence(
            ["running", "requires_action", "running", "idle"],
            in: Self.stateMarkers(in: updates))
        let wireText = try encodedWireText(of: updates)
        #expect(wireText.contains(Self.acceptedAnswer))
        #expect(wireText.contains(Self.acceptedResultText))
    }

    /// A declined form elicitation reaches the tool as `decline`, and the
    /// turn still ends `end_turn`.
    @Test(.timeLimit(.minutes(1)))
    func aDeclinedFormElicitationReachesTheToolAsDecline() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.formSnippet, label: "ElicitationRelayTests-form-decline")
        try await Self.prompt(fixture)
        let pending = try await Self.waitForPendingElicitation(in: fixture)

        await MainActor.run {
            fixture.harness.client.declineElicitation(pending.id)
        }
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        let creates = await Self.recordedCreates(of: fixture)
        await fixture.close()

        #expect(creates.count == 1)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
        #expect(try encodedWireText(of: updates).contains(Self.declinedResultText))
    }

    // MARK: - The capability gate

    /// A client with no `elicitation` capability makes the tool receive
    /// `decline`, and no `elicitation/create` is sent.
    @Test(.timeLimit(.minutes(1)))
    func aClientWithoutTheCapabilityMakesTheToolReceiveDeclineAndNothingIsSent() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.formSnippet,
            capabilities: ClientCapabilities(),
            label: "ElicitationRelayTests-no-capability")
        try await Self.prompt(fixture)

        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        let creates = await Self.recordedCreates(of: fixture)
        await fixture.close()

        #expect(creates.isEmpty)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
        #expect(!Self.stateMarkers(in: updates).contains("requires_action"))
        #expect(try encodedWireText(of: updates).contains(Self.declinedResultText))
    }

    /// A client with `form` only, asked in `url` mode, receives nothing —
    /// the relay never falls back to form — and the tool receives
    /// `decline`.
    @Test(.timeLimit(.minutes(1)))
    func aFormOnlyClientAskedInURLModeReceivesNothingAndTheToolReceivesDecline() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.urlSnippet,
            capabilities: Self.formOnlyCapabilities,
            label: "ElicitationRelayTests-form-only-url")
        try await Self.prompt(fixture)

        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        let creates = await Self.recordedCreates(of: fixture)
        await fixture.close()

        #expect(creates.isEmpty)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
        #expect(!Self.stateMarkers(in: updates).contains("requires_action"))
        #expect(try encodedWireText(of: updates).contains(Self.declinedResultText))
    }

    // MARK: - The URL round trip

    /// URL mode: create, accept, then `elicitation/complete` reaches the
    /// client, and the tool resumes with the accept.
    @Test(.timeLimit(.minutes(1)))
    func aURLElicitationCompletesAfterAcceptAndTheCompletionReachesTheClient() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.urlSnippet, label: "ElicitationRelayTests-url-accept")
        try await Self.prompt(fixture)

        let pending = try await Self.waitForPendingElicitation(in: fixture)
        #expect(pending.request.message == ScriptedServer.elicitURLMessage)
        #expect(pending.url?.absoluteString == ScriptedServer.elicitURLLink)
        let elicitationId = try #require(pending.elicitationId)

        await MainActor.run {
            fixture.harness.client.acceptElicitation(pending.id)
        }
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        let recorder = try #require(fixture.harness.elicitations)
        let completions = await recorder.completions
        await fixture.close()

        #expect(completions.map(\.elicitationId) == [elicitationId])
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
        expectOrderedSubsequence(
            ["running", "requires_action", "running", "idle"],
            in: Self.stateMarkers(in: updates))
        #expect(try encodedWireText(of: updates).contains(Self.acceptedResultText))
    }

    // MARK: - Cancellation

    /// `session/cancel` during a pending elicitation delivers `cancel` to
    /// the tool before `idle(cancelled)`: the round trip resolves — the
    /// post-answer `running` goes out — and only then the idle terminator.
    /// The URL-mode tool is used here, so the cancel also releases an
    /// outstanding URL elicitation id.
    @Test(.timeLimit(.minutes(1)))
    func sessionCancelDuringAPendingElicitationDeliversCancelBeforeIdle() async throws {
        let fixture = try await Self.makeLoopbackFixture(
            code: Self.urlSnippet, label: "ElicitationRelayTests-cancel")
        try await Self.prompt(fixture)
        _ = try await Self.waitForPendingElicitation(in: fixture)

        try await fixture.harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: fixture.sessionId))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.close()

        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .cancelled)
        expectOrderedSubsequence(
            ["requires_action", "running", "idle"],
            in: Self.stateMarkers(in: updates))
    }

    /// The recorded `elicitation/create` requests of the fixture.
    ///
    /// - Parameter fixture: The wired fixture.
    /// - Returns: The recorded requests, in arrival order.
    private static func recordedCreates(
        of fixture: ScriptedTurnFixture
    ) async -> [CreateElicitationRequest] {
        await fixture.harness.elicitations?.creates ?? []
    }
}

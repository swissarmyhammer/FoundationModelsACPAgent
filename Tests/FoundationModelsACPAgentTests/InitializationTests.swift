import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPClient
import Testing

/// The `initialize` handshake of `RoutedACPAgent` (plan.md §5 and §6):
/// version negotiation, the advertised capabilities, the order rule, and
/// the refused authentication methods.
@Suite struct InitializationTests {
    /// The protocol version a client older than v2 sends.
    static let protocolVersion1 = ProtocolVersion(rawValue: 1)

    /// The protocol version as the wire spells it: a bare integer.
    static let protocolVersion2WireValue = JSONValue.number(
        Double(ACPClient.supportedProtocolVersion.rawValue))

    /// The JSON-RPC wire value of "method not found".
    static let methodNotFoundWireValue = -32601

    /// The JSON-RPC wire value of "invalid request".
    static let invalidRequestWireValue = -32600

    /// A session id no session has, so that the order rule is the only
    /// thing a pre-initialize session call can trip on.
    static let unknownSessionId = SessionId(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV")

    /// Encodes a wire model and decodes it back as a JSON tree, so a test
    /// can assert the shape that crosses the wire.
    ///
    /// - Parameter model: The wire model.
    /// - Returns: The JSON tree of the model.
    /// - Throws: Rethrows the coder's errors.
    static func jsonTree(of model: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(model))
    }

    /// Runs `body` and asserts that it throws a `RequestError` with `code`.
    ///
    /// - Parameters:
    ///   - code: The expected error code.
    ///   - wireValue: The integer `code` must have on the wire.
    ///   - body: The call that must fail.
    static func expectRequestError(
        _ code: ErrorCode, wireValue: Int, from body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("expected a \(code) error")
        } catch let error as RequestError {
            #expect(error.code == code)
            #expect(error.code.wireValue == wireValue)
        } catch {
            Issue.record("expected a RequestError, got \(error)")
        }
    }

    // MARK: - Negotiation

    /// A client that sends `2` gets `2` back, with the implementation
    /// identity and no authentication surface.
    @Test(.timeLimit(.minutes(1)))
    func initializeEchoesVersion2AndReportsTheImplementation() async throws {
        let harness = try await AgentClientHarness.make()
        let response = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        await harness.close()

        #expect(response.protocolVersion == ACPClient.supportedProtocolVersion)
        #expect(response.info == RoutedACPAgent.implementation)
        #expect(response.info.name != AgentClientHarness.dotfolderName)
        #expect(!response.info.version.isEmpty)
        #expect(response.info.title != nil)
        #expect(response.authMethods == nil)
        #expect(response.capabilities == RoutedACPAgent.advertisedCapabilities)
    }

    /// A client that sends `1` gets `2` back in a normal, successful
    /// response, not an error (plan.md §5).
    @Test func initializeWithVersion1AnswersVersion2Successfully() async throws {
        let agent = try await AgentClientHarness.makeAgent()
        let response = try await agent.initialize(
            AgentClientHarness.makeInitializeRequest(protocolVersion: Self.protocolVersion1))

        #expect(response.protocolVersion == .v2)
        #expect(response.info == RoutedACPAgent.implementation)
    }

    /// Over the wire, the v2-only client sees the successful `2` answer to
    /// its `1`, and then decides to disconnect with its own mismatch error.
    @Test(.timeLimit(.minutes(1)))
    func initializeWithVersion1ReachesTheClientAsASuccessfulVersion2Answer() async throws {
        let harness = try await AgentClientHarness.make()
        do {
            _ = try await harness.connection.initialize(
                AgentClientHarness.makeInitializeRequest(protocolVersion: Self.protocolVersion1))
            Issue.record("expected the client's own protocol-version mismatch error")
        } catch let error as ProtocolVersionMismatchError {
            #expect(error.sent == Self.protocolVersion1)
            #expect(error.received == .v2)
        }
        await harness.close()
    }

    // MARK: - Capabilities

    /// The response carries `capabilities.session` with the four markers as
    /// objects, `mcp` with both transports, `prompt` with the honest
    /// `embeddedContext` marker (plan.md §12), and nothing else: no auth
    /// and no permission capability (plan.md §5, §11.7).
    @Test(.timeLimit(.minutes(1)))
    func advertisedCapabilitiesCarryTheFourSessionMarkersAsObjects() async throws {
        let harness = try await AgentClientHarness.make()
        let response = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        await harness.close()

        let tree = try Self.jsonTree(of: response.capabilities)
        guard case .object(let root) = tree, case .object(let session) = root["session"] ?? .null else {
            Issue.record("expected capabilities.session to be an object, got \(tree)")
            return
        }
        #expect(Set(root.keys) == ["session"])
        #expect(Set(session.keys) == ["additionalDirectories", "delete", "mcp", "prompt"])
        #expect(session["additionalDirectories"] == .object([:]))
        #expect(session["delete"] == .object([:]))
        #expect(session["prompt"] == .object(["embeddedContext": .object([:])]))
        #expect(session["mcp"] == .object(["stdio": .object([:]), "http": .object([:])]))
        #expect(response.capabilities.auth == nil)
    }

    // MARK: - Reading the client's capabilities

    /// Before `initialize`, nothing is negotiated. An advertised elicitation
    /// capability is read as supported; an absent one as unsupported.
    @Test func clientCapabilitiesAreReadWithAbsentMeaningUnsupported() async throws {
        let agent = try await AgentClientHarness.makeAgent()
        #expect(await agent.negotiatedClientCapabilities == nil)

        _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())
        let advertised = try #require(await agent.negotiatedClientCapabilities)
        #expect(advertised.supportsFormElicitation)
        #expect(advertised.supportsURLElicitation)

        _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest(capabilities: ClientCapabilities()))
        let absent = try #require(await agent.negotiatedClientCapabilities)
        #expect(!absent.supportsFormElicitation)
        #expect(!absent.supportsURLElicitation)
    }

    /// A `capabilities` value that is not an object degrades to "supports
    /// nothing" and does not fail `initialize` (plan.md §5).
    @Test(.timeLimit(.minutes(1)))
    func malformedClientCapabilitiesDegradeToSupportsNothing() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = try await AgentClientHarness.makeAgent()
        let agentConnection = await AgentSideConnection(stream: agentEnd) { _ in agent }
        let frames = NDJSONCodec.frames(from: clientEnd.bytes, logger: .disabled)

        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("initialize"),
            "params": .object([
                "info": .object(["name": .string("raw-client"), "version": .string("1.0.0")]),
                "protocolVersion": Self.protocolVersion2WireValue,
                "capabilities": .string("not an object"),
            ]),
        ])
        try await clientEnd.write(NDJSONCodec.encode(request))

        var iterator = frames.makeAsyncIterator()
        let frame = try #require(try await iterator.next())
        guard case .message(.object(let fields)) = frame, case .object(let result) = fields["result"] ?? .null else {
            Issue.record("expected a successful initialize response, got \(frame)")
            return
        }
        #expect(fields["error"] == nil)
        #expect(result["protocolVersion"] == Self.protocolVersion2WireValue)

        let negotiated = try #require(await agent.negotiatedClientCapabilities)
        #expect(!negotiated.supportsFormElicitation)
        #expect(!negotiated.supportsURLElicitation)

        await agentConnection.close()
        clientEnd.close()
    }

    // MARK: - The order rule

    /// Each `session/*` request of the stable v2 surface.
    enum SessionMethod: CaseIterable {
        case new, list, resume, close, prompt, delete

        /// Sends this request over `connection`.
        ///
        /// - Parameter connection: The client side of the wire.
        /// - Throws: The agent's error.
        func call(over connection: ClientSideConnection) async throws {
            let cwd = try #require(AbsolutePath(rawValue: "/"))
            let sessionId = InitializationTests.unknownSessionId
            switch self {
            case .new:
                _ = try await connection.newSession(NewSessionRequest(cwd: cwd))
            case .list:
                _ = try await connection.listSessions(ListSessionsRequest())
            case .resume:
                _ = try await connection.resumeSession(ResumeSessionRequest(cwd: cwd, sessionId: sessionId))
            case .close:
                _ = try await connection.closeSession(CloseSessionRequest(sessionId: sessionId))
            case .prompt:
                _ = try await connection.prompt(PromptRequest(prompt: [], sessionId: sessionId))
            case .delete:
                _ = try await connection.deleteSession(DeleteSessionRequest(sessionId: sessionId))
            }
        }
    }

    /// Any `session/*` request before `initialize` gets a JSON-RPC
    /// invalid-request error (plan.md §5).
    @Test(.timeLimit(.minutes(1)), arguments: SessionMethod.allCases)
    func sessionMethodBeforeInitializeGivesInvalidRequest(method: SessionMethod) async throws {
        let harness = try await AgentClientHarness.make()
        await Self.expectRequestError(.invalidRequest, wireValue: Self.invalidRequestWireValue) {
            try await method.call(over: harness.connection)
        }
        await harness.close()
    }

    // MARK: - No authentication surface

    /// `auth/login` and `auth/logout` get `-32601`, never `-32000`
    /// (plan.md §6).
    @Test(.timeLimit(.minutes(1)))
    func authMethodsGiveMethodNotFound() async throws {
        let harness = try await AgentClientHarness.make()
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())

        await Self.expectRequestError(.methodNotFound, wireValue: Self.methodNotFoundWireValue) {
            _ = try await harness.connection.loginAuth(
                LoginAuthRequest(methodId: AuthMethodId(rawValue: "none")))
        }
        await Self.expectRequestError(.methodNotFound, wireValue: Self.methodNotFoundWireValue) {
            _ = try await harness.connection.logoutAuth(LogoutAuthRequest())
        }
        await harness.close()
    }
}

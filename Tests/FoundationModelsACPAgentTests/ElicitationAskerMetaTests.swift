import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// Who asks one question (task ^6ay176q, elicitation phase 4): the
/// `_meta` of `elicitation/create` carries `agentPath` and `source`, each
/// only when it is not empty. AgentViewKit shows them in the header of the
/// question card.
@Suite(.closesHarnesses) struct ElicitationAskerMetaTests {
    // MARK: - Constants

    /// The message of each request.
    private static let requestMessage = "Which colour do you want?"

    /// The one field of the form of each form request.
    private static let answerField = "answer"

    /// The link of each URL request.
    private static let requestLink = "https://example.com/sign-in"

    /// The tool call of each mapped request.
    private static let toolCallId = "asker-call-1"

    /// The session of each mapped request.
    private static let sessionId = SessionId(rawValue: syntheticSessionIdValue)

    /// The tool of the run that posts a question of the root session.
    private static let runCodeTool = "runCode"

    /// The agent that asked, one level below the root.
    private static let reviewerAgent = "reviewer"

    /// The agent that asked, two levels below the root.
    private static let linterAgent = "linter"

    /// The source that an MCP server question carries.
    private static let serverSource = "github"

    /// The two modes of a request.
    enum RequestMode: CaseIterable {
        /// A form request.
        case form

        /// A URL request.
        case url
    }

    // MARK: - Helpers

    /// A request in `mode`, with `source`.
    ///
    /// - Parameters:
    ///   - mode: The mode of the request.
    ///   - source: The source of the request, or `nil`.
    /// - Returns: The request.
    /// - Throws: When ``requestLink`` does not parse as a URL.
    private static func makeRequest(_ mode: RequestMode = .form, source: String? = nil) throws -> ElicitationRequest {
        switch mode {
        case .form:
            ElicitationRequest(
                message: requestMessage,
                elicitationId: ULID(),
                requestedSchema: ElicitationRequestedSchema(
                    properties: [answerField: .string(ElicitationStringSchema())],
                    required: [answerField]),
                source: source)
        case .url:
            ElicitationRequest(
                message: requestMessage, elicitationId: ULID(), url: try #require(URL(string: requestLink)),
                source: source)
        }
    }

    /// The `_meta` members of the wire request of `request`.
    ///
    /// - Parameters:
    ///   - request: The request the tool posted.
    ///   - tool: The tool of the run that posted it.
    /// - Returns: The members, or `nil` when the wire request has no `_meta`.
    /// - Throws: When the request does not map, or its `_meta` is not an
    ///   object.
    private static func metaMembers(
        of request: ElicitationRequest, tool: String = runCodeTool
    ) throws -> [String: FoundationModelsACP.JSONValue]? {
        let wire = try #require(
            ElicitationRelay.wireRequest(for: request, sessionId: sessionId, toolCallId: toolCallId, tool: tool))
        guard let meta = wire.meta else {
            return nil
        }
        guard case .object(let members) = meta else {
            Issue.record("expected an object _meta, got \(meta)")
            return nil
        }
        return members
    }

    /// The JSON object of `text`, or `nil` when it is not an object.
    ///
    /// - Parameter text: The JSON text.
    /// - Returns: The members.
    private static func object(of text: String) -> [String: FoundationModelsACP.JSONValue]? {
        guard
            case .object(let members) = try? JSONDecoder().decode(
                FoundationModelsACP.JSONValue.self, from: Data(text.utf8))
        else {
            return nil
        }
        return members
    }

    // MARK: - The wire mapping

    /// A question of the root session has no path, and its source is the
    /// tool of the run. This is true in both modes.
    @Test(arguments: RequestMode.allCases)
    func aRootQuestionCarriesTheToolOfItsRunAsTheSourceAndNoPath(mode: RequestMode) throws {
        let members = try #require(try Self.metaMembers(of: try Self.makeRequest(mode)))

        #expect(members == [ElicitationAskerMeta.sourceKey: .string(Self.runCodeTool)])
    }

    /// A question that one child relayed carries the name of the child, and
    /// the source that the relay set.
    @Test func aQuestionOfAChildCarriesItsAgentAndTheSourceOfTheRelay() throws {
        let request = try Self.makeRequest().relayed(by: Self.reviewerAgent, askedBy: Self.runCodeTool)

        let members = try #require(try Self.metaMembers(of: request, tool: Self.reviewerAgent))

        #expect(members[ElicitationAskerMeta.agentPathKey] == .array([.string(Self.reviewerAgent)]))
        #expect(members[ElicitationAskerMeta.sourceKey] == .string(Self.runCodeTool))
    }

    /// A question of a grandchild carries the path from the agent nearest
    /// the user to the agent that asked.
    @Test func aQuestionOfAGrandchildCarriesThePathInOrder() throws {
        let request = try Self.makeRequest()
            .relayed(by: Self.linterAgent, askedBy: Self.runCodeTool)
            .relayed(by: Self.reviewerAgent, askedBy: Self.runCodeTool)

        let members = try #require(try Self.metaMembers(of: request))

        #expect(
            members[ElicitationAskerMeta.agentPathKey]
                == .array([.string(Self.reviewerAgent), .string(Self.linterAgent)]))
    }

    /// The source of the request wins over the tool of the run: an MCP
    /// server question asks through the `runCode` run that called the
    /// server.
    @Test func theSourceOfTheRequestWinsOverTheToolOfTheRun() throws {
        let members = try #require(try Self.metaMembers(of: try Self.makeRequest(source: Self.serverSource)))

        #expect(members[ElicitationAskerMeta.sourceKey] == .string(Self.serverSource))
    }

    /// With no path and no source, the wire request has no `_meta`.
    @Test func aQuestionWithNoPathAndNoSourceHasNoMeta() throws {
        #expect(try Self.metaMembers(of: try Self.makeRequest(), tool: "") == nil)
    }

    /// The encoded request has `_meta` as one more member, and the other
    /// members are the same as the request with no `_meta`.
    @Test func theEncodedRequestHasMetaBesideTheSameMembers() throws {
        let request = try Self.makeRequest()
        let withMeta = try #require(
            ElicitationRelay.wireRequest(
                for: request, sessionId: Self.sessionId, toolCallId: Self.toolCallId, tool: Self.runCodeTool))
        var withoutMeta = withMeta
        withoutMeta.meta = nil

        let encoded = try #require(Self.object(of: String(decoding: try JSONEncoder().encode(withMeta), as: UTF8.self)))
        let plain = try #require(Self.object(of: String(decoding: try JSONEncoder().encode(withoutMeta), as: UTF8.self)))

        #expect(encoded["_meta"] == .object([ElicitationAskerMeta.sourceKey: .string(Self.runCodeTool)]))
        #expect(encoded.filter { $0.key != "_meta" } == plain)
    }

    // MARK: - The wire

    /// The marker of the prompt whose snippet asks.
    private static let askMarker = "Ask who you are"

    /// The snippet that asks one question.
    private static let askingSnippet = #"return await elicit("Which colour do you want?");"#

    /// The `elicitation/create` that a `runCode` snippet of the root session
    /// sends carries the source `runCode` and no path. The fixed point is the
    /// pending question at the client: the client got the line before it
    /// made the question.
    @Test func theCreateOfARunCodeQuestionCarriesItsSourceOnTheWire() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            loader: makeScriptedModelLoader(
                script: try ScriptedPromptFixture.makeToolPromptScript(
                    code: Self.askingSnippet, onPromptContaining: Self.askMarker)),
            label: "ElicitationAskerMetaTests-wire",
            tapsWire: true)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.askMarker))
        let question = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
        let lines = await (try #require(fixture.harness.wireTap)).lines
        await MainActor.run {
            fixture.session.acceptElicitation(
                question.id, content: .object([Self.answerField: .string("blue")]))
        }
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        let creates = lines.compactMap(Self.object(of:)).filter {
            $0["method"] == .string("elicitation/create")
        }
        #expect(creates.count == 1)
        let params = try #require(creates.first?["params"])
        guard case .object(let members) = params else {
            Issue.record("expected object params, got \(params)")
            return
        }
        #expect(members["_meta"] == .object([ElicitationAskerMeta.sourceKey: .string(Self.runCodeTool)]))
    }
}

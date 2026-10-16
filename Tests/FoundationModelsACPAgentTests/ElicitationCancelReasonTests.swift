import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
@testable import FoundationModelsExtras
@testable import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The reason of the `$/cancel_request` of a question (FoundationModelsACP
/// task 50): when Router ends a question with no answer of the client, the
/// relay sets the reason of the end on the cancellation box of the
/// `elicitation/create` before it cancels the request. Thus the
/// `$/cancel_request` frame carries `_meta.reason`.
@Suite struct ElicitationCancelReasonTests {
    /// The marker of the prompt whose snippet asks.
    private static let askMarker = "Ask and wait"

    /// The snippet that asks one question.
    private static let askingSnippet = #"return await elicit("Which colour do you want?");"#

    /// The method of the cancel notification on the wire.
    private static let cancelRequestMethod = "$/cancel_request"

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

    /// A cancel of the run of an open question sends one `$/cancel_request`
    /// whose `_meta.reason` is the reason of the end that Router sent:
    /// "run cancelled". The fixed point is the client: it removes the
    /// question when it reads the cancel, and the tap records the line
    /// before the client reads it.
    @Test func aCancelOfTheRunSendsTheReasonInTheCancelRequest() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            loader: makeScriptedModelLoader(
                script: try ScriptedPromptFixture.makeToolPromptScript(
                    code: Self.askingSnippet, onPromptContaining: Self.askMarker)),
            label: "ElicitationCancelReasonTests-run-cancel",
            tapsWire: true)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.askMarker))
        let pending = try await ElicitationWait.firstPendingElicitation(in: fixture.session)
        guard case .form(let form) = pending.request.mode, case .session(let scope) = form.scope,
            let toolCallId = scope.toolCallId
        else {
            Issue.record("expected a form request scoped to a tool call, got \(pending.request.mode)")
            await fixture.close()
            return
        }

        let session = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.session)
        let actor = try #require(session as? RoutedSessionActor)
        _ = await actor.runPlane.cancel(completionToken: toolCallId.rawValue)
        try await ElicitationWait.waitUntilNoPendingElicitation(in: fixture.session)
        let lines = await (try #require(fixture.harness.wireTap)).lines
        await fixture.close()

        let cancels = lines.compactMap(Self.object(of:)).filter {
            $0["method"] == .string(Self.cancelRequestMethod)
        }
        #expect(cancels.count == 1)
        let params = try #require(cancels.first?["params"])
        guard case .object(let members) = params else {
            Issue.record("expected object params, got \(params)")
            return
        }
        #expect(
            members["_meta"]
                == .object([CancelRequestNotification.reasonMetaKey: .string(RunPlane.runCancelledReason)]))
    }
}

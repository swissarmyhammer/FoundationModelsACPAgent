import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
@testable import FoundationModelsExtras
@testable import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// One question that waits for the user in a fresh session of a scripted
/// fixture. The relay of the session carries the question to the client
/// over the wire, as a tool question does, and the client holds it.
struct OpenQuestion {
    /// The wired fixture whose session holds the question.
    let fixture: ScriptedPromptFixture

    /// The id of the question.
    let elicitationId: ULID

    /// The relay of the session, which carries the question.
    let relay: ElicitationRelay

    /// The round trip of the relay. It ends when the question ends.
    private let roundTrip: Task<Void, Never>

    /// Opens one question in a fresh session and waits until the client
    /// holds it.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - answerDelivery: The delivery that the session reports for the
    ///     answer, or `nil` for the delivery of the real session.
    ///   - makeRequest: Makes the question from its id.
    /// - Returns: The open question.
    /// - Throws: Whatever the wiring or the wait throws.
    static func open(
        label: String, answerDelivery: ElicitationAnswerDelivery? = nil, _ makeRequest: (ULID) throws -> ElicitationRequest
    ) async throws -> OpenQuestion {
        let fixture = try await ScriptedPromptFixture.make(script: [], label: label)
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        let relay = try #require(entry.projector.relay)
        let session = CloseCountingRoutedSession(wrapping: entry.session)
        await session.setAnswerDelivery(answerDelivery)
        let elicitationId = ULID()
        let event = OperationEvent(
            tool: "elicitor", op: "elicit", correlationID: "open-question", kind: .elicitation, detail: "",
            elicitation: try makeRequest(elicitationId))
        let roundTrip = Task { await relay.relay(event, on: session) }
        let clientSession = fixture.session
        try await ObservedValue.wait(for: "the question reaches the client") {
            !clientSession.pendingElicitations.isEmpty
        }
        return OpenQuestion(fixture: fixture, elicitationId: elicitationId, relay: relay, roundTrip: roundTrip)
    }

    /// Ends the question with a cancel of the client, and waits until the
    /// relay is done with it.
    func cancel() async {
        let clientSession = fixture.session
        await MainActor.run {
            for pending in clientSession.pendingElicitations {
                clientSession.cancelElicitation(pending.id)
            }
        }
        await roundTrip.value
    }

    /// Accepts the question at the client, and waits until the round trip of
    /// the relay returns.
    func accept() async {
        let clientSession = fixture.session
        await MainActor.run {
            for pending in clientSession.pendingElicitations {
                clientSession.acceptElicitation(pending.id)
            }
        }
        await roundTrip.value
    }

    /// A URL-mode request.
    ///
    /// - Parameter elicitationId: The id the request carries.
    /// - Returns: The request.
    /// - Throws: When the fixed link does not parse as a URL.
    static func makeURLRequest(elicitationId: ULID) throws -> ElicitationRequest {
        ElicitationRequest(
            message: "Sign in to go on.", elicitationId: elicitationId,
            url: try #require(URL(string: "https://example.com/sign-in")))
    }

    /// A form-mode request with one string field.
    ///
    /// - Parameter elicitationId: The id the request carries.
    /// - Returns: The request.
    static func makeFormRequest(elicitationId: ULID) -> ElicitationRequest {
        ElicitationRequest(
            message: "Which colour do you want?",
            elicitationId: elicitationId,
            requestedSchema: ElicitationRequestedSchema(
                properties: ["answer": .string(ElicitationStringSchema())],
                required: ["answer"]))
    }
}

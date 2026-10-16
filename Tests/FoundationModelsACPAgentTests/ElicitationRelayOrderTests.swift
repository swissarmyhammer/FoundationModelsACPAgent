import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
@testable import FoundationModelsExtras
@testable import FoundationModelsRouter
import Observation
import Testing

@testable import FoundationModelsACPAgent

/// Rule R2 of elicitation-plan.md section 10: a relay sends no
/// `elicitation/create` for a question that has an end.
///
/// The projector starts each `relay(_:on:)` in its own task, with no fixed
/// order. Thus the end of a question, and the end of the feed, can come to
/// the relay before the round trip of the question. Each test calls the
/// relay directly in that order. The fixed point of each test is the late
/// `relay(_:on:)`: it returns, or its question reaches the client. A test
/// that sees the question at the client cancels it there, so the round trip
/// of the old code ends too.
@Suite struct ElicitationRelayOrderTests {
    /// The name of the tool that posts the questions of the tests.
    private static let askingTool = "elicitor"

    /// A form-mode request with one string field.
    ///
    /// - Parameter elicitationId: The id the request carries.
    /// - Returns: The request.
    private static func makeFormRequest(elicitationId: ULID) -> ElicitationRequest {
        ElicitationRequest(
            message: "Which colour do you want?",
            elicitationId: elicitationId,
            requestedSchema: ElicitationRequestedSchema(
                properties: ["answer": .string(ElicitationStringSchema())],
                required: ["answer"]))
    }

    /// The parts of one test: the fixture, its relay, and a double of its
    /// Router session that records each answer.
    private struct Parts {
        /// The wired fixture.
        let fixture: ScriptedPromptFixture

        /// The relay of the session of the fixture.
        let relay: ElicitationRelay

        /// The double that records the answers that go to Router.
        let session: CloseCountingRoutedSession
    }

    /// Wires a fixture, reads the relay of its session, runs `body`, and
    /// closes the fixture. The fixture closes also when `body` throws.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - body: The work of the test.
    /// - Returns: What `body` returns.
    /// - Throws: When the wiring fails, when the session or its relay is
    ///   missing, or what `body` throws.
    private static func withParts<Result>(
        label: String, _ body: (Parts) async throws -> Result
    ) async throws -> Result {
        let fixture = try await ScriptedPromptFixture.make(script: [], label: label)
        do {
            let entry = await fixture.harness.agent.sessions[fixture.sessionId]
            guard let relay = await entry?.projector.relay, let session = entry?.session else {
                throw MissingRelay()
            }
            let result = try await body(
                Parts(fixture: fixture, relay: relay, session: CloseCountingRoutedSession(wrapping: session)))
            await fixture.close()
            return result
        } catch {
            await fixture.close()
            throw error
        }
    }

    /// The error of a fixture whose session has no relay.
    private struct MissingRelay: Error {}

    /// Whether the late `relay(_:on:)` of a test returned. The wait of the
    /// test observes it, with the questions of the client.
    @MainActor @Observable final class RelayReturn {
        /// Whether the call returned.
        var returned = false
    }

    /// Runs one late `relay(_:on:)` of `request`, and waits until it returns
    /// or its question reaches the client. A question at the client gets a
    /// cancel there, so the round trip ends.
    ///
    /// - Parameters:
    ///   - request: The request to relay.
    ///   - parts: The parts of the test.
    /// - Returns: The `elicitation/create` requests that reached the client.
    /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled first.
    private static func relayLate(_ request: ElicitationRequest, in parts: Parts) async throws
        -> [CreateElicitationRequest]
    {
        let event = OperationEvent(
            tool: askingTool, op: "elicit", correlationID: "relay-late", kind: .elicitation, detail: "",
            elicitation: request)
        let relayReturn = await RelayReturn()
        let late = Task {
            await parts.relay.relay(event, on: parts.session)
            await MainActor.run { relayReturn.returned = true }
        }
        let clientSession = parts.fixture.session
        try await ObservedValue.wait(for: "the late relay returns, or its question reaches the client") {
            relayReturn.returned || !clientSession.pendingElicitations.isEmpty
        }
        await MainActor.run {
            for pending in clientSession.pendingElicitations {
                clientSession.cancelElicitation(pending.id)
            }
        }
        await late.value
        return await parts.fixture.harness.elicitations?.creates ?? []
    }

    /// The scenario of the 2026-10-16 check: Router ends a question, and
    /// the feed ends, before the round trip of the question starts. The
    /// drain must not forget the end. Thus the late round trip sends no
    /// `elicitation/create`, and it does not answer Router again: Router
    /// already gave the run the response of the end.
    @Test func aLateRelayOfAQuestionThatEndedBeforeTheDrainSendsNoCreate() async throws {
        let (creates, responses) = try await Self.withParts(label: "ElicitationRelayOrderTests-end-then-drain") {
            parts in
            let elicitationId = ULID()
            await parts.relay.end(
                ElicitationEnd(elicitationId: elicitationId, response: .cancel(reason: RunPlane.runCancelledReason)))
            await parts.relay.drainOpenRoundTrips()
            let creates = try await Self.relayLate(Self.makeFormRequest(elicitationId: elicitationId), in: parts)
            return (creates, await parts.session.responses.map(\.response))
        }

        #expect(creates.isEmpty)
        #expect(responses.isEmpty)
    }

    /// A round trip that starts after the end of the feed sends no
    /// `elicitation/create`. It gives Router `cancel` with the reason of the
    /// feed end, so the suspended tool resumes and knows why.
    @Test func aLateRelayAfterTheDrainSendsNoCreateAndGivesRouterCancelWithTheReason() async throws {
        let (creates, responses) = try await Self.withParts(label: "ElicitationRelayOrderTests-drain-then-relay") {
            parts in
            await parts.relay.drainOpenRoundTrips()
            let creates = try await Self.relayLate(Self.makeFormRequest(elicitationId: ULID()), in: parts)
            return (creates, await parts.session.responses.map(\.response))
        }

        #expect(creates.isEmpty)
        #expect(responses == [.cancel(reason: ElicitationRelay.feedEndedCancelReason)])
    }

    /// A round trip that is still in flight at the drain gives Router
    /// `cancel` with the same reason that its `$/cancel_request` carries
    /// (rule R4). The fixed point is the open question at the client: the
    /// wait also ends when the round trip returns before it.
    @Test func theDrainGivesRouterTheReasonOfTheFeedEnd() async throws {
        let responses = try await Self.withParts(label: "ElicitationRelayOrderTests-drain-reason") { parts in
            let event = OperationEvent(
                tool: Self.askingTool, op: "elicit", correlationID: "relay-drain", kind: .elicitation, detail: "",
                elicitation: Self.makeFormRequest(elicitationId: ULID()))
            let relayReturn = await RelayReturn()
            let roundTrip = Task {
                await parts.relay.relay(event, on: parts.session)
                await MainActor.run { relayReturn.returned = true }
            }
            let clientSession = parts.fixture.session
            try await ObservedValue.wait(for: "the question reaches the client, or the round trip returns") {
                relayReturn.returned || !clientSession.pendingElicitations.isEmpty
            }
            await parts.relay.drainOpenRoundTrips()
            await roundTrip.value
            return await parts.session.responses.map(\.response)
        }

        #expect(responses == [.cancel(reason: ElicitationRelay.feedEndedCancelReason)])
    }
}

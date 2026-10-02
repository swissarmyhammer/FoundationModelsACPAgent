import Foundation
import FoundationModels
import FoundationModelsRouter

// MARK: - A Router session double that counts its closes
//
// A test that must prove when a Router session closes, and how many
// times, wraps a real session in this double. Each call goes to the real
// session. The double adds two facts: the number of `close()` calls, and
// each fork it made, so a test can read the count of a child too.

/// A `RoutedSession` that sends each call to a real session and counts
/// the calls to ``close()``.
///
/// ``fork(workingDirectory:)`` wraps the real child in a new double and
/// keeps it in ``forks``, so a test can read the close count of the
/// child as well as the count of the parent.
///
/// A synchronous requirement cannot send its call to the actor of the
/// real session, because that call needs an `await`. The code under test
/// does not use these requirements, so each one stops the test with a
/// message that names it.
actor CloseCountingRoutedSession: RoutedSession {
    /// The real session that each call goes to.
    private let wrapped: any RoutedSession

    /// The number of calls to ``close()``.
    private(set) var closeCount = 0

    /// Each double that ``fork(workingDirectory:)`` made, in fork order.
    private(set) var forks: [CloseCountingRoutedSession] = []

    /// Wraps `wrapped`.
    ///
    /// - Parameter wrapped: The real session that each call goes to.
    init(wrapping wrapped: any RoutedSession) {
        self.wrapped = wrapped
    }

    // MARK: The identity, from the real session

    /// The profile of the real session.
    nonisolated var profile: LanguageModelProfile { wrapped.profile }

    /// The router id of the real session.
    nonisolated var routerId: ULID { wrapped.routerId }

    /// The span id of the real session.
    nonisolated var id: ULID { wrapped.id }

    /// The parent span id of the real session.
    nonisolated var parentId: ULID? { wrapped.parentId }

    /// The recording directory of the real session.
    nonisolated var recordingDirectory: URL { wrapped.recordingDirectory }

    /// The working directory of the real session.
    nonisolated var workingDirectory: URL { wrapped.workingDirectory }

    /// The grammar of the real session.
    nonisolated var grammar: Grammar? { wrapped.grammar }

    /// The context fill of the real session.
    var contextFill: Double {
        get async { await wrapped.contextFill }
    }

    /// The transcript of the real session.
    var transcript: Transcript {
        get async { await wrapped.transcript }
    }

    // MARK: The counted calls

    /// Counts the call, and then closes the real session.
    func close() async {
        closeCount += 1
        await wrapped.close()
    }

    /// Forks the real session, and wraps the child in a new double that
    /// ``forks`` keeps.
    ///
    /// - Parameter workingDirectory: The working directory of the child.
    /// - Returns: The new double over the real child.
    /// - Throws: Whatever the fork of the real session throws.
    func fork(workingDirectory: URL?) async throws -> RoutedSession {
        let child = CloseCountingRoutedSession(
            wrapping: try await wrapped.fork(workingDirectory: workingDirectory))
        forks.append(child)
        return child
    }

    // MARK: The calls that go to the real session

    /// Sends the call to the real session.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt.
    ///   - budget: The token budget.
    /// - Returns: The result of the real session.
    /// - Throws: Whatever the real session throws.
    func compact(prompt: CompactionPrompt, budget: TokenBudget?) async throws -> CompactionResult {
        try await wrapped.compact(prompt: prompt, budget: budget)
    }

    /// Sends the call to the real session.
    ///
    /// - Parameters:
    ///   - prompt: The prompt.
    ///   - maxTokens: The token ceiling.
    /// - Returns: The answer of the real session.
    /// - Throws: Whatever the real session throws.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await wrapped.respond(to: prompt, maxTokens: maxTokens)
    }

    /// Sends the call to the real session.
    ///
    /// - Returns: The result of the real session.
    func cancel() async -> CancellationResult {
        await wrapped.cancel()
    }

    /// Sends the call to the real session.
    ///
    /// - Returns: Whether the real session drained.
    func drain() async -> Bool {
        await wrapped.drain()
    }

    /// Sends the call to the real session.
    ///
    /// - Returns: Whether the real session became idle.
    func awaitIdle() async -> Bool {
        await wrapped.awaitIdle()
    }

    /// Sends the call to the real session.
    ///
    /// - Parameter message: The id of the message to take back.
    /// - Returns: The result of the real session.
    func cancel(message: MessageID) async -> MessageCancellationResult {
        await wrapped.cancel(message: message)
    }

    /// Sends the call to the real session.
    ///
    /// - Parameter prompt: The message to send.
    /// - Returns: The id of the message.
    func send(_ prompt: Transcript.Prompt) async -> MessageID {
        await wrapped.send(prompt)
    }

    /// Sends the call to the real session.
    ///
    /// - Returns: The waiting messages of the real session.
    func pendingMessages() async -> [(id: MessageID, prompt: Transcript.Prompt)] {
        await wrapped.pendingMessages()
    }

    /// Sends the call to the real session.
    ///
    /// - Parameters:
    ///   - id: The id of the waiting message.
    ///   - prompt: The new message.
    /// - Returns: The result of the real session.
    func replace(id: MessageID, prompt: Transcript.Prompt) async -> MessageQueueMutationResult {
        await wrapped.replace(id: id, prompt: prompt)
    }

    /// Sends the call to the real session.
    ///
    /// - Returns: The queue depth of the real session.
    func messageQueueDepth() async -> MessageQueueDepth {
        await wrapped.messageQueueDepth()
    }

    /// Sends the call to the real session.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the pending elicitation.
    ///   - response: The answer of the user.
    /// - Returns: The result of the real session.
    func respond(elicitationId: String, response: ElicitationResponse) async -> ElicitationAnswerDelivery {
        await wrapped.respond(elicitationId: elicitationId, response: response)
    }

    /// Sends the call to the real session.
    ///
    /// - Parameter elicitationId: The id of the accepted elicitation.
    /// - Returns: The result of the real session.
    func complete(elicitationId: String) async -> ElicitationCompletionDelivery {
        await wrapped.complete(elicitationId: elicitationId)
    }

    // MARK: The synchronous calls, which the code under test does not use

    /// Stops the test: this double cannot send a synchronous call to the
    /// real session.
    ///
    /// - Parameters:
    ///   - prompt: The prompt.
    ///   - maxTokens: The token ceiling.
    /// - Returns: Never returns.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        preconditionFailure("CloseCountingRoutedSession does not support streamResponse(to:maxTokens:)")
    }

    /// Stops the test: this double cannot send a synchronous call to the
    /// real session.
    ///
    /// - Parameters:
    ///   - prompt: The prompt.
    ///   - maxTokens: The token ceiling.
    /// - Returns: Never returns.
    func streamEvents(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<SessionEvent, Error> {
        preconditionFailure("CloseCountingRoutedSession does not support streamEvents(to:maxTokens:)")
    }

    /// Stops the test: this double cannot send a synchronous call to the
    /// real session.
    ///
    /// - Returns: Never returns.
    func streamSessionEvents() -> AsyncStream<SessionEvent> {
        preconditionFailure("CloseCountingRoutedSession does not support streamSessionEvents()")
    }

    /// Stops the test: this double cannot send a synchronous call to the
    /// real session.
    ///
    /// - Parameter interval: The stall report interval.
    func setGenerationStallReportInterval(_ interval: Duration) {
        preconditionFailure("CloseCountingRoutedSession does not support setGenerationStallReportInterval(_:)")
    }
}

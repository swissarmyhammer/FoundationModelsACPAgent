import Foundation
import FoundationModels
import FoundationModelsExtras
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
/// A `nonisolated` requirement goes to the real session at once, because
/// the real session declares it `nonisolated` too. A synchronous requirement
/// that the real session isolates cannot go to the actor of the real
/// session, because that call needs an `await`. The code under test does not
/// use these requirements, so each one stops the test with a message that
/// names it.
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
    func fork(workingDirectory: URL?) async throws -> any RoutedSession {
        let child = CloseCountingRoutedSession(
            wrapping: try await wrapped.fork(workingDirectory: workingDirectory))
        forks.append(child)
        return child
    }

    // MARK: The mail and the signals, which go to the real session at once

    /// Sends the mail to the real session.
    ///
    /// - Parameter mail: The mail.
    /// - Returns: The subscription of the real session.
    /// - Throws: Whatever the real session throws.
    nonisolated func mail(_ mail: Mail) throws -> MailSubscription<SessionOutput> {
        try wrapped.mail(mail)
    }

    /// Sends the prompt to the real session.
    ///
    /// - Parameter prompt: The prompt.
    /// - Returns: The id of the mail.
    /// - Throws: Whatever the real session throws.
    @discardableResult
    nonisolated func send(_ prompt: Transcript.Prompt) throws -> MailID {
        try wrapped.send(prompt)
    }

    /// Sends the compaction signal to the real session.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt.
    ///   - budget: The token budget.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func compact(prompt: CompactionPrompt, budget: TokenBudget?) -> SignalID {
        wrapped.compact(prompt: prompt, budget: budget)
    }

    /// Sends the cancel signal of one mail to the real session.
    ///
    /// - Parameter id: The id of the queued mail.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func cancel(_ id: MailID) -> SignalID {
        wrapped.cancel(id)
    }

    /// Sends the cancel signal of all work to the real session.
    ///
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func cancelAll() -> SignalID {
        wrapped.cancelAll()
    }

    /// Sends the replace signal to the real session.
    ///
    /// - Parameters:
    ///   - id: The id of the queued mail.
    ///   - body: The new body of the mail.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func replace(_ id: MailID, with body: MailBody) -> SignalID {
        wrapped.replace(id, with: body)
    }

    // MARK: The calls that go to the real session

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
    /// - Parameter id: The id of the mail.
    /// - Returns: The terminal event of the mail.
    /// - Throws: Whatever the real session throws.
    func awaitTerminal(of id: MailID) async throws -> SessionEvent {
        try await wrapped.awaitTerminal(of: id)
    }

    /// Sends the call to the real session.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The answer of the mail.
    /// - Throws: Whatever the real session throws.
    func awaitAnswer(of id: MailID) async throws -> SessionAnswer {
        try await wrapped.awaitAnswer(of: id)
    }

    /// Sends the call to the real session.
    ///
    /// - Parameter id: The id of the signal.
    /// - Returns: The terminal event of the signal.
    /// - Throws: Whatever the real session throws.
    func awaitTerminal(of id: SignalID) async throws -> SessionEvent {
        try await wrapped.awaitTerminal(of: id)
    }

    /// Sends the call to the real session.
    ///
    /// - Returns: Whether the real session became idle.
    func awaitIdle() async -> Bool {
        await wrapped.awaitIdle()
    }

    /// Sends the call to the real session.
    ///
    /// - Returns: The queued mail of the real session.
    func pendingMessages() async -> [Mail] {
        await wrapped.pendingMessages()
    }

    /// Sends the call to the real session.
    ///
    /// - Returns: The mail queue depth of the real session.
    func mailQueueDepth() async -> MailQueueDepth {
        await wrapped.mailQueueDepth()
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
    func streamSessionEvents() -> AsyncStream<SessionOutput> {
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

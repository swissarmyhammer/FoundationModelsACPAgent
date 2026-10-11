import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool

@testable import FoundationModelsACPAgent
// `SubmissionID` has an internal initializer only: the session mints the
// ids. A synthetic event stream still needs one, and a debug build compiles
// Router with testing enabled, so the fixtures below reach it this way.
@testable import FoundationModelsRouter

// MARK: - The synthetic submission events

/// The one submission id the synthetic streams carry. The projection reads
/// no id, so one value serves every event.
private let syntheticSubmissionId = SubmissionID(0)

/// The `submissionQueued` event of one synthetic submission: the
/// submission waits for a place in the model queue.
///
/// - Returns: The event.
func makeSubmissionQueued() -> SessionEvent {
    .submissionQueued(syntheticSubmissionId)
}

/// The `submissionStarted` event of one synthetic submission.
///
/// - Parameter cause: Why the session made the submission. A retry after
///   a context overflow or a rejected tool call is a `continuation`.
/// - Returns: The event.
func makeSubmissionStarted(cause: SubmissionStart.Cause = .message) -> SessionEvent {
    .submissionStarted(
        SubmissionStart(submissionId: syntheticSubmissionId, messageIds: [], cause: cause))
}

/// The `submissionEnded` event of one synthetic submission, with `usage`
/// and its finish reason.
///
/// - Parameter usage: The measured usage of the submission.
/// - Returns: The event.
func makeSubmissionEnded(_ usage: TokenUsage) -> SessionEvent {
    .submissionEnded(
        SubmissionEnd(
            submissionId: syntheticSubmissionId, usage: usage, finishReason: usage.finishReason))
}

extension SessionAnswer {
    /// Makes the final answer of one synthetic chain of submissions.
    ///
    /// The Router sends the `answered` event after the `submissionEnded`
    /// event of the last submission. Its usage is the total of the chain,
    /// so it holds tokens that each `submissionEnded` event already gave.
    ///
    /// - Parameter usage: The total usage of the chain.
    /// - Returns: The answer.
    static func makeSynthetic(usage: TokenUsage) -> SessionAnswer {
        SessionAnswer(
            reply: "", messageIds: [], usage: usage, compactions: [], toolCalls: [],
            toolInvocations: [])
    }
}

// MARK: - The synthetic projection fixtures
//
// The projection tests drive `PromptExecution.drive(events:)` with a
// synthetic event stream and record each update the prompt sends. No
// session and no model is necessary for that. `PromptExecutionTests` and
// `EventProjectionTests` share these fixtures.

/// A well-formed ULID that names no live session. The synthetic tests
/// run a prompt without a session table, so the value never resolves.
let syntheticSessionIdValue = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

/// The model reference a synthetic prompt reports. No model stands behind
/// a scripted event stream, and the name says so.
let syntheticModelName = "synthetic-model"

/// A sink that collects every update a prompt sends.
actor SinkRecorder {
    /// Tells if the updates that a reader waits for are all recorded.
    typealias Completion = @Sendable ([SessionUpdate]) -> Bool

    /// One reader that waits for more updates.
    private struct Waiter {
        /// Tells if the updates of the reader are all recorded.
        let isComplete: Completion

        /// The wait of the reader.
        let continuation: CheckedContinuation<[SessionUpdate], Never>
    }

    /// The collected updates, in send order.
    private(set) var updates: [SessionUpdate] = []

    /// The readers that wait for more updates.
    private var waiters: [Waiter] = []

    /// Appends one update, and resumes each reader whose updates are now
    /// all recorded.
    ///
    /// - Parameter update: The update to record.
    func append(_ update: SessionUpdate) {
        updates.append(update)
        let recorded = updates
        let ready = waiters.filter { $0.isComplete(recorded) }
        waiters.removeAll { $0.isComplete(recorded) }
        for waiter in ready {
            waiter.continuation.resume(returning: recorded)
        }
    }

    /// The recorded updates, as soon as `isComplete` accepts them. When it
    /// does not accept the updates of now, it waits for more updates.
    ///
    /// - Parameter isComplete: Tells if the updates are all recorded.
    /// - Returns: The recorded updates, in send order.
    func updates(until isComplete: @escaping Completion) async -> [SessionUpdate] {
        if isComplete(updates) {
            return updates
        }
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(isComplete: isComplete, continuation: continuation))
        }
    }
}

/// Makes a prompt execution over a recording sink. The synthetic stream tests
/// drive `drive(events:)` directly and never touch a session.
///
/// - Parameter shellSnapshot: The reader of a settled run's stored
///   output; the default finds no run.
/// - Returns: The execution and the recorder of its updates.
func makeSinkedExecution(
    shellSnapshot: @escaping ShellSnapshotProvider = { _ in nil }
) -> (execution: PromptExecution, recorder: SinkRecorder) {
    let recorder = SinkRecorder()
    let send: SessionUpdateSink = { update in await recorder.append(update) }
    let execution = PromptExecution(
        sessionId: SessionId(rawValue: syntheticSessionIdValue),
        promptBlocks: [],
        promptState: PromptStateOwner(send: send),
        send: send,
        firstActivity: nil,
        modelName: syntheticModelName,
        shellSnapshot: shellSnapshot)
    return (execution, recorder)
}

/// Makes a finished synthetic stream of `events`.
///
/// - Parameters:
///   - events: The events to yield, in order.
///   - error: The terminal error, or `nil` for a clean finish.
/// - Returns: The stream.
func makeEventStream(
    _ events: [SessionEvent], throwing error: (any Error)? = nil
) -> AsyncThrowingStream<SessionEvent, Error> {
    AsyncThrowingStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish(throwing: error)
    }
}

/// The one driver of a synthetic prompt. The projection suites use it to
/// send a scripted event stream through a sinked prompt execution.
enum SyntheticPrompt {
    /// Drives one synthetic prompt of `events` through a sinked prompt
    /// execution.
    ///
    /// - Parameters:
    ///   - events: The events of the prompt, in order.
    ///   - error: The error that ends the stream after the events, or `nil`
    ///     for a stream that ends by itself.
    ///   - shellSnapshot: The reader of the stored output of a settled
    ///     run; the default finds no run.
    /// - Returns: The updates that the prompt sent, in send order, and the
    ///   stop reason of the prompt.
    static func drive(
        _ events: [SessionEvent],
        throwing error: (any Error)? = nil,
        shellSnapshot: @escaping ShellSnapshotProvider = { _ in nil }
    ) async -> (updates: [SessionUpdate], reason: StopReason) {
        let (execution, recorder) = makeSinkedExecution(shellSnapshot: shellSnapshot)
        let reason = await execution.drive(events: makeEventStream(events, throwing: error))
        return (await recorder.updates, reason)
    }

    /// Drives one synthetic prompt of `events` and gives only the updates
    /// that it sent. Use this form when the test does not read the stop
    /// reason.
    ///
    /// - Parameters:
    ///   - events: The events of the prompt, in order.
    ///   - error: The error that ends the stream after the events, or `nil`
    ///     for a stream that ends by itself.
    ///   - shellSnapshot: The reader of the stored output of a settled
    ///     run; the default finds no run.
    /// - Returns: The updates that the prompt sent, in send order.
    static func sentUpdates(
        _ events: [SessionEvent],
        throwing error: (any Error)? = nil,
        shellSnapshot: @escaping ShellSnapshotProvider = { _ in nil }
    ) async -> [SessionUpdate] {
        await drive(events, throwing: error, shellSnapshot: shellSnapshot).updates
    }

    /// The order in which ``sentUpdates(_:shellEvents:order:)`` starts the two
    /// consumers of one shell run.
    enum ShellRunOrder {
        /// The prompt handles each of its events, the open record too, before
        /// the terminal stream reads the first shell event.
        case promptFirst

        /// The terminal stream reads the first shell event before the prompt
        /// handles the open record of the run.
        case terminalFirst
    }

    /// Drives one synthetic prompt of `events` and one terminal stream of
    /// `shellEvents` into one recorder, as a session does: the prompt and
    /// the terminal stream send through the same sink, and they share one
    /// ``RunCallJoinTable``.
    ///
    /// - Parameters:
    ///   - events: The events of the prompt, in order.
    ///   - shellEvents: The live shell events of the session, in order.
    ///   - order: Which consumer starts first.
    /// - Returns: The updates that the prompt and the terminal stream sent,
    ///   in send order.
    static func sentUpdates(
        _ events: [SessionEvent],
        shellEvents: [ShellOutputEvent],
        order: ShellRunOrder
    ) async -> [SessionUpdate] {
        let session = SinkedShellSession(runCallJoins: RunCallJoinTable())
        let terminal = { @Sendable in
            var stream = session.terminal
            await stream.consume(makeShellEventStream(shellEvents))
        }
        switch order {
        case .promptFirst:
            await session.execution.drive(events: makeEventStream(events))
            await terminal()
        case .terminalFirst:
            let terminalTask = Task(operation: terminal)
            await session.execution.drive(events: makeEventStream(events))
            await terminalTask.value
        }
        return await session.recorder.updates
    }
}

/// The one driver of a prompt over a real Router session. The scripted model
/// plays its script, Router mounts and runs the tools, and the prompt sends
/// each update to a recorder. Thus a test reads the real order of the Router
/// events on the wire.
enum RoutedPrompt {
    /// The text of the prompt when the caller gives none.
    static let defaultPrompt = "Call the tool."

    /// Runs one prompt over a real routed session whose scripted model plays
    /// `script`, and gives each update that the prompt sent.
    ///
    /// - Parameters:
    ///   - prompt: The text of the prompt. A script can play a step only for
    ///     this prompt (``ScriptedPassStep/onPrompt(containing:play:)``), and
    ///     not for an answer that the mail of a background run starts.
    ///   - script: The steps that the model plays on each pass.
    ///   - tools: The tools of the session.
    ///   - label: The directory label of the calling test.
    /// - Returns: The sent updates, in send order.
    /// - Throws: Whatever the profile or the session throws.
    static func sentUpdates(
        prompt: String = defaultPrompt, script: [ScriptedPassStep], tools: [any FoundationModels.Tool],
        label: String
    ) async throws -> [SessionUpdate] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try await makeStubProfile(
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true),
            loader: makeScriptedModelLoader(script: script))
        let session = profile.standard.makeBudgetedSession(
            instructions: "Call the tool.",
            workingDirectory: directory,
            recordingRoot: directory.appendingPathComponent("recordings", isDirectory: true),
            tools: tools,
            compaction: CompactionConfiguration(),
            repetition: RepetitionConfiguration(),
            inlineSettleGrace: CatalogContext.defaultInlineSettleGrace)
        let (sinkedExecution, recorder) = makeSinkedExecution()
        var execution = sinkedExecution
        execution.modelPrompt = prompt
        await execution.run(session: session)
        await session.close()
        return await recorder.updates
    }
}

/// The parts of one sinked session: a prompt execution and a terminal stream
/// that send through one recorder and share one ``RunCallJoinTable``, as in
/// a session. The prompt is open when the value is made, as
/// `PromptExecution.run` opens it before its events.
struct SinkedShellSession {
    /// The prompt execution over the join table.
    let execution: PromptExecution

    /// The recorder of each update that the prompt and the terminal stream
    /// send.
    let recorder: SinkRecorder

    /// The terminal stream over the join table.
    let terminal: TerminalStream

    /// Makes the parts over `runCallJoins`, and opens the prompt.
    ///
    /// - Parameters:
    ///   - runCallJoins: The join table of the session.
    ///   - snapshot: The reader of the stored output of a run; the default
    ///     finds no run.
    init(runCallJoins: RunCallJoinTable, snapshot: @escaping ShellSnapshotProvider = { _ in nil }) {
        let (sinkedExecution, recorder) = makeSinkedExecution()
        var execution = sinkedExecution
        execution.runCallJoins = runCallJoins
        runCallJoins.openPrompt()
        self.execution = execution
        self.recorder = recorder
        terminal = TerminalStream(snapshot: snapshot, runCallJoins: runCallJoins) { update in
            await recorder.append(update)
        }
    }
}

/// Makes a finished stream of live shell events.
///
/// - Parameter events: The events to yield, in order.
/// - Returns: The stream.
func makeShellEventStream(_ events: [ShellOutputEvent]) -> AsyncStream<ShellOutputEvent> {
    AsyncStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

/// One live session for a test that sets the order of the prompt events and
/// the shell events itself. One prompt and one terminal stream send through
/// one recorder and share one ``RunCallJoinTable``, as in a session. The
/// prompt starts when the value is made, and it stays open until
/// ``finish()``.
struct LiveShellSession {
    /// The join table that the prompt and the terminal stream share.
    let runCallJoins: RunCallJoinTable

    /// The recorder of each update that the prompt and the terminal stream
    /// sent.
    let recorder: SinkRecorder

    /// The input of the event stream of the prompt.
    private let promptEvents: AsyncThrowingStream<SessionEvent, Error>.Continuation

    /// The input of the shell output stream of the session.
    private let shellEvents: AsyncStream<ShellOutputEvent>.Continuation

    /// The task that drives the prompt.
    private let prompt: Task<Void, Never>

    /// The task that consumes the shell output stream.
    private let terminal: Task<Void, Never>

    /// Starts one prompt and one terminal stream over `runCallJoins`.
    ///
    /// - Parameter runCallJoins: The join table of the session.
    init(runCallJoins: RunCallJoinTable = RunCallJoinTable()) {
        let session = SinkedShellSession(runCallJoins: runCallJoins)
        let (promptStream, promptEvents) = AsyncThrowingStream.makeStream(of: SessionEvent.self)
        let (shellStream, shellEvents) = AsyncStream.makeStream(of: ShellOutputEvent.self)
        self.runCallJoins = runCallJoins
        recorder = session.recorder
        self.promptEvents = promptEvents
        self.shellEvents = shellEvents
        prompt = Task {
            await session.execution.drive(events: promptStream)
        }
        terminal = Task {
            var stream = session.terminal
            await stream.consume(shellStream)
        }
    }

    /// Gives one event to the prompt.
    ///
    /// - Parameter event: The session event.
    func send(_ event: SessionEvent) {
        promptEvents.yield(event)
    }

    /// Gives one event to the terminal stream.
    ///
    /// - Parameter event: The live shell event.
    func send(_ event: ShellOutputEvent) {
        shellEvents.yield(event)
    }

    /// Ends the prompt, then the shell output stream, and waits for both
    /// consumers.
    ///
    /// - Returns: Each update that the prompt and the terminal stream sent,
    ///   in send order.
    func finish() async -> [SessionUpdate] {
        promptEvents.finish()
        await prompt.value
        shellEvents.finish()
        await terminal.value
        return await recorder.updates
    }
}

// MARK: - The update readers

/// The tool-call updates in the sequence, in order.
///
/// - Parameter updates: The sent updates.
/// - Returns: The tool-call updates.
func toolCallUpdates(in updates: [SessionUpdate]) -> [ToolCallUpdate] {
    updates.compactMap { update in
        if case .toolCallUpdate(let call) = update { return call }
        return nil
    }
}

/// The terminal output chunks in the sequence, in order.
///
/// - Parameter updates: The sent updates.
/// - Returns: The chunks.
func terminalChunks(in updates: [SessionUpdate]) -> [TerminalOutputChunk] {
    updates.compactMap { update in
        if case .terminalOutputChunk(let chunk) = update { return chunk }
        return nil
    }
}

/// The terminal updates in the sequence, in order.
///
/// - Parameter updates: The sent updates.
/// - Returns: The terminal updates.
func terminalUpdates(in updates: [SessionUpdate]) -> [TerminalUpdate] {
    updates.compactMap { update in
        if case .terminalUpdate(let terminal) = update { return terminal }
        return nil
    }
}

// MARK: - The single-update readers
//
// Each reader RETURNS an optional, so a test unwraps it with
// `try #require` or checks it with `#expect`. A `guard` inside a
// reader gives a value to its caller; it never ends a test.

/// The value a patch field carries.
///
/// - Parameter field: The patch field to read.
/// - Returns: The carried value, or `nil` when the field is
///   `unchanged` or `cleared`.
func patchValue<Wrapped: Codable & Hashable & Sendable>(
    _ field: PatchField<Wrapped>
) -> Wrapped? {
    guard case .value(let value) = field else { return nil }
    return value
}

/// The idle state one update carries.
///
/// - Parameter update: The update to read.
/// - Returns: The idle state, or `nil` when the update is something
///   else.
func idleState(of update: SessionUpdate?) -> IdleStateUpdate? {
    guard case .stateUpdate(.idle(let idle)) = update else { return nil }
    return idle
}

/// Whether one update is the `idle` state update.
///
/// - Parameter update: The update to read.
/// - Returns: `true` for an idle state update.
func isIdleState(_ update: SessionUpdate?) -> Bool {
    idleState(of: update) != nil
}

/// Whether one update is the `running` state update.
///
/// - Parameter update: The update to read.
/// - Returns: `true` for a running state update.
func isRunningState(_ update: SessionUpdate?) -> Bool {
    if case .stateUpdate(.running) = update { return true }
    return false
}

/// Whether one update is the `requires_action` state update.
///
/// - Parameter update: The update to read.
/// - Returns: `true` for a requires-action state update.
func isRequiresActionState(_ update: SessionUpdate?) -> Bool {
    if case .stateUpdate(.requiresAction) = update { return true }
    return false
}

/// The user-message echo one update carries.
///
/// - Parameter update: The update to read.
/// - Returns: The echo, or `nil` when the update is something else.
func userMessageEcho(of update: SessionUpdate?) -> UserMessage? {
    guard case .userMessage(let echo) = update else { return nil }
    return echo
}

/// The agent-message chunk one update carries.
///
/// - Parameter update: The update to read.
/// - Returns: The chunk, or `nil` when the update is something else.
func agentMessageChunk(of update: SessionUpdate?) -> ContentChunk? {
    guard case .agentMessageChunk(let chunk) = update else { return nil }
    return chunk
}

/// The whole-message replace one update carries.
///
/// - Parameter update: The update to read.
/// - Returns: The replace, or `nil` when the update is something
///   else.
func agentMessageReplace(of update: SessionUpdate?) -> AgentMessage? {
    guard case .agentMessage(let message) = update else { return nil }
    return message
}

/// The usage report one update carries.
///
/// - Parameter update: The update to read.
/// - Returns: The report, or `nil` when the update is something else.
func usageReport(of update: SessionUpdate?) -> UsageUpdate? {
    guard case .usageUpdate(let usage) = update else { return nil }
    return usage
}

/// The terminal update one update carries.
///
/// - Parameter update: The update to read.
/// - Returns: The terminal update, or `nil` when the update is
///   something else.
func terminalUpdate(of update: SessionUpdate?) -> TerminalUpdate? {
    guard case .terminalUpdate(let terminal) = update else { return nil }
    return terminal
}

// MARK: - The JSON value readers

/// The wire object of one update: the update goes through the JSON codec
/// of the transport, so a test reads the members that cross the wire, and
/// it can see that an omitted field is absent and not `null`.
///
/// - Parameter update: The sent update.
/// - Returns: The members of the encoded update, or `nil` when the update
///   does not encode as a JSON object.
/// - Throws: The encoding or the decoding error.
func wireObject(of update: SessionUpdate) throws -> [String: FoundationModelsACP.JSONValue]? {
    jsonObject(
        of: try JSONDecoder().decode(
            FoundationModelsACP.JSONValue.self, from: JSONEncoder().encode(update)))
}

extension Array where Element == SessionUpdate {
    /// The title that the client shows at the end for one tool call: the
    /// last `title` that an update of the call put on the wire. An update
    /// that omits `title` does not change the title on the client.
    ///
    /// - Parameter toolCallId: The wire id of the tool call.
    /// - Returns: The last title, or `nil` when no update of the call sent
    ///   one.
    /// - Throws: The encoding error of an update.
    func lastWireTitle(ofToolCall toolCallId: String) throws -> String? {
        try compactMap { try wireObject(of: $0) }
            .filter { jsonString(of: $0["toolCallId"]) == toolCallId }
            .compactMap { jsonString(of: $0["title"]) }
            .last
    }

    /// The `status` of each update of one tool call that put a status on the
    /// wire, in send order. An update that omits `status` adds nothing.
    ///
    /// - Parameter toolCallId: The wire id of the tool call.
    /// - Returns: The wire statuses.
    /// - Throws: The encoding error of an update.
    func wireStatuses(ofToolCall toolCallId: String) throws -> [String] {
        try compactMap { try wireObject(of: $0) }
            .filter { jsonString(of: $0["toolCallId"]) == toolCallId }
            .compactMap { jsonString(of: $0["status"]) }
    }

    /// The status that the client shows at the end for one tool call: the
    /// client merges each update, as ``SessionMergeEngine`` does.
    ///
    /// - Parameter toolCallId: The wire id of the tool call.
    /// - Returns: The merged status, or `nil` when the client has no such
    ///   call or the call has no status.
    func clientStatus(ofToolCall toolCallId: String) -> FoundationModelsACP.ToolCallStatus? {
        let merged = SessionMergeEngine(replaying: self)
        guard case .toolCall(let call)? = merged.entry(withID: .toolCall(ToolCallId(rawValue: toolCallId)))?.kind
        else {
            return nil
        }
        return patchValue(call.status)
    }
}

/// The members a JSON object carries.
///
/// - Parameter value: The JSON value to read, or `nil`.
/// - Returns: The members, or `nil` when the value is absent or
///   carries something else.
func jsonObject(
    of value: FoundationModelsACP.JSONValue?
) -> [String: FoundationModelsACP.JSONValue]? {
    guard case .object(let members) = value else { return nil }
    return members
}

/// The string a JSON value carries.
///
/// - Parameter value: The JSON value to read, or `nil`.
/// - Returns: The string, or `nil` when the value is absent or carries
///   something else.
func jsonString(of value: FoundationModelsACP.JSONValue?) -> String? {
    guard case .string(let text) = value else { return nil }
    return text
}

/// The text of every plain-content item in a content patch.
///
/// - Parameter content: The content patch to read.
/// - Returns: The texts, in item order.
func texts(in content: PatchField<[ToolCallContent]>) -> [String] {
    guard case .value(let items) = content else { return [] }
    return items.compactMap { item in
        if case .content(let wrapped) = item, case .text(let text) = wrapped.content {
            return text.text
        }
        return nil
    }
}

/// The terminal id of every `Terminal` content item in a patch.
///
/// - Parameter content: The content patch to read.
/// - Returns: The terminal ids, in item order.
func terminalIds(in content: PatchField<[ToolCallContent]>) -> [String] {
    guard case .value(let items) = content else { return [] }
    return items.compactMap { item in
        if case .terminal(let terminal) = item { return terminal.terminalId.rawValue }
        return nil
    }
}

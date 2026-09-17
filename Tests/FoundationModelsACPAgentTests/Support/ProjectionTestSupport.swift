import Foundation
import FoundationModelsACP
import FoundationModelsMultitool
import FoundationModelsRouter

@testable import FoundationModelsACPAgent

// MARK: - The synthetic projection fixtures (plan.md §20.1)
//
// The projection tests drive `PromptTurn.drive(events:)` with a
// synthetic event stream and record each update the turn sends. No
// session and no model is necessary for that. `PromptTurnTests` and
// `EventProjectionTests` share these fixtures.

/// A well-formed ULID that names no live session. The synthetic tests
/// run a turn without a session table, so the value never resolves.
let syntheticSessionIdValue = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

/// The model reference a synthetic turn reports. No model stands behind
/// a scripted event stream, and the name says so.
let syntheticModelName = "synthetic-model"

/// A sink that collects every update a turn sends.
actor SinkRecorder {
    /// The collected updates, in send order.
    private(set) var updates: [SessionUpdate] = []

    /// Appends one update.
    ///
    /// - Parameter update: The update to record.
    func append(_ update: SessionUpdate) {
        updates.append(update)
    }
}

/// Makes a turn over a recording sink. The synthetic stream tests
/// drive `drive(events:)` directly and never touch a session.
///
/// - Parameter shellSnapshot: The reader of a settled run's stored
///   output; the default finds no run.
/// - Returns: The turn and the recorder of its updates.
func makeSinkedTurn(
    shellSnapshot: @escaping ShellSnapshotProvider = { _ in nil }
) -> (turn: PromptTurn, recorder: SinkRecorder) {
    let recorder = SinkRecorder()
    let send: SessionUpdateSink = { update in await recorder.append(update) }
    let turn = PromptTurn(
        sessionId: SessionId(rawValue: syntheticSessionIdValue),
        promptBlocks: [],
        turnState: TurnStateOwner(send: send),
        send: send,
        firstActivity: nil,
        modelName: syntheticModelName,
        shellSnapshot: shellSnapshot)
    return (turn, recorder)
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

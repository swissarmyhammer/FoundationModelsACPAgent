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

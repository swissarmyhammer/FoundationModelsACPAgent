import FoundationModelsACP

/// The tool calls that one prompt sent, so that the prompt can close each
/// tool call that did not finish before its `idle`.
///
/// The ACP v2 prompt lifecycle wants a failed prompt to set each open tool
/// call to `failed`, and a cancelled prompt to send each final update before
/// its `idle`. The prompt sends its tool-call updates through
/// ``recording(into:)``, and at its end it asks
/// ``unfinishedToolCallIds()`` which calls are still open.
///
/// The record is a `SessionMergeEngine` of the tool-call updates of the
/// prompt alone, so the merge rules of ACP decide the status of each call,
/// and `cancelUnfinishedToolCalls()` decides which status is not terminal.
actor PromptToolCalls {
    /// The merged tool-call updates of the prompt.
    private var merged = SessionMergeEngine()

    /// A sink that records each tool-call update and then gives each update
    /// to `send`.
    ///
    /// - Parameter send: The sink of the prompt.
    /// - Returns: The recording sink.
    nonisolated func recording(into send: @escaping SessionUpdateSink) -> SessionUpdateSink {
        { update in
            await self.record(update)
            await send(update)
        }
    }

    /// The ids of the tool calls that did not finish: each call whose last
    /// status is not `completed`, `failed` or `cancelled`. The order is the
    /// order of the first update of each call.
    ///
    /// - Returns: The ids of the open tool calls.
    func unfinishedToolCallIds() -> [ToolCallId] {
        var probe = merged
        return probe.cancelUnfinishedToolCalls().compactMap(Self.toolCallId(of:))
    }

    /// Merges `update` when it is a tool-call update. The record keeps no
    /// other update.
    ///
    /// - Parameter update: The update that the prompt sends.
    private func record(_ update: SessionUpdate) {
        guard case .toolCallUpdate = update else {
            return
        }
        merged.apply(update)
    }

    /// The tool-call id of a change of the merge engine, or `nil` for a
    /// change of another entry.
    ///
    /// - Parameter change: A change of the merge engine.
    /// - Returns: The tool-call id, or `nil`.
    private static func toolCallId(of change: SessionMergeEngine.Change) -> ToolCallId? {
        guard case .entryChanged(_, let entry) = change, case .toolCall(let toolCall) = entry.kind else {
            return nil
        }
        return toolCall.toolCallId
    }
}

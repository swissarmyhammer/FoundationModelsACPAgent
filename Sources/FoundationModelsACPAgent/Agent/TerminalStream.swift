import Foundation
import FoundationModelsACP
import FoundationModelsMultitool

/// The terminal display projection (plan.md §11.8): the one mapping
/// from the host-owned `ShellOutputChunkStream` to the wire's
/// display-only terminal updates.
///
/// The identity rule is §11.8's: a shell run's `commandID` is its
/// `correlationID`, its `completionToken`, and its `toolCallId` — one
/// string — and it maps to the run's `terminalId`. Each event kind maps
/// to one wire shape:
///
/// - The first event of a run sends the `tool_call_update` whose
///   content is the `Terminal` reference, so the client can attach the
///   terminal to the call before any byte arrives.
/// - `.output(stream:bytes:)` becomes one `terminal_output_chunk`,
///   base64-encoded on its own. The bytes stay true: no UTF-8 decode
///   and no lossy text coercion touches them.
/// - `.gap(stream:droppedByteCount:)` becomes one `TerminalUpdate`
///   whose `output` is the authoritative replacement built from
///   `snapshot(for:)` — the ACP replace is made for a client that lost
///   bytes to backpressure.
/// - `.completed` becomes one `TerminalUpdate` whose `exitStatus` is
///   present with neither an exit code nor a signal: the presence marks
///   exited, which agrees with a soft-deadline kill, and the exit code
///   does not cross the module boundary on this stream. The final
///   output replacement rides beside it.
///
/// One value consumes one stream, because the upstream stream hands
/// each event out exactly once — run exactly one loop (§11.8).
struct TerminalStream {
    /// The reader of a run's stored raw output, for the gap and
    /// completion replacements. The production reader is the same
    /// stream's `snapshot(for:)`.
    let snapshot: ShellSnapshotProvider

    /// The sink every update of this projection goes to.
    let send: SessionUpdateSink

    /// The runs whose `Terminal` reference already went out. A run
    /// leaves the set at its completion marker, because no later event
    /// carries its `commandID`.
    private var announcedRuns: Set<String> = []

    /// Makes a projection over `snapshot` and `send`.
    ///
    /// - Parameters:
    ///   - snapshot: The reader of a run's stored raw output.
    ///   - send: The sink every update goes to.
    init(snapshot: @escaping ShellSnapshotProvider, send: @escaping SessionUpdateSink) {
        self.snapshot = snapshot
        self.send = send
    }

    /// Starts the one consumer loop over the host-owned stream.
    ///
    /// The task ends when the stream finishes — `finish()` at session
    /// teardown, or the stream's own deinit — and the session lifecycle
    /// keeps the handle so a teardown can cancel it (plan.md §11.8).
    ///
    /// - Parameters:
    ///   - stream: The host-owned stream to consume. Its
    ///     `snapshot(for:)` backs the gap and completion replacements.
    ///   - send: The sink every update goes to.
    /// - Returns: The running consumer task.
    @discardableResult
    static func start(
        over stream: ShellOutputChunkStream, send: @escaping SessionUpdateSink
    ) -> Task<Void, Never> {
        Task {
            var projection = TerminalStream(
                snapshot: { commandID in stream.snapshot(for: commandID) },
                send: send)
            await projection.consume(stream)
        }
    }

    /// Consumes `events` to its end, projecting each one.
    ///
    /// - Parameter events: The live stream, usually a
    ///   `ShellOutputChunkStream`.
    mutating func consume<Events: AsyncSequence<ShellOutputEvent, Never>>(
        _ events: Events
    ) async {
        for await event in events {
            await project(event)
        }
    }

    /// Projects one live shell event to the wire.
    ///
    /// - Parameter event: The event to project.
    mutating func project(_ event: ShellOutputEvent) async {
        await announceRunIfNew(event.commandID)
        switch event.kind {
        case .output(_, let bytes):
            await send(
                .terminalOutputChunk(
                    TerminalOutputChunk(
                        data: Data(bytes).base64EncodedString(),
                        terminalId: TerminalId(rawValue: event.commandID))))
        case .gap:
            await replaceOutput(of: event.commandID)
        case .completed:
            await reportExit(of: event.commandID)
            announcedRuns.remove(event.commandID)
        @unknown default:
            // The upstream kind is not frozen: a new case degrades to a
            // log line, never to a broken stream.
            turnLogger.debug(
                "run \(event.commandID, privacy: .public): unprojected shell output event")
        }
    }

    /// The `Terminal` content reference of one run, for the tool call
    /// that owns it. The settlement projection reuses it (§11.8).
    ///
    /// - Parameter commandID: The run's completion token.
    /// - Returns: The content item.
    static func terminalItem(for commandID: String) -> ToolCallContent {
        .terminal(Terminal(terminalId: TerminalId(rawValue: commandID)))
    }

    /// The authoritative replacement record of one run: the stored
    /// stdout then the stored stderr, as one base64 blob —
    /// `TerminalOutput` carries one byte sequence, not two streams.
    ///
    /// - Parameter snapshot: The run's stored raw output.
    /// - Returns: The replacement record.
    static func output(of snapshot: ShellOutputSnapshot) -> TerminalOutput {
        TerminalOutput(
            data: Data(snapshot.stdout.bytes + snapshot.stderr.bytes).base64EncodedString())
    }

    /// Sends the run's `Terminal` reference at its first event: one
    /// `tool_call_update` keyed by the `commandID`, saying the call
    /// runs — the first update with an unseen id is the creation, and
    /// a creation must not leave `pending` in place (§11.6).
    ///
    /// - Parameter commandID: The run the event belongs to.
    private mutating func announceRunIfNew(_ commandID: String) async {
        guard announcedRuns.insert(commandID).inserted else { return }
        await send(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: ToolCallId(rawValue: commandID),
                    content: .value([Self.terminalItem(for: commandID)]),
                    status: .value(.inProgress))))
    }

    /// Replaces the client's view of one run with the stored record: a
    /// gap said bytes went away, and the snapshot is the "replace" half
    /// of the stream's contract. A run the store never saw is logged;
    /// the client keeps its view until the completion replacement.
    ///
    /// - Parameter commandID: The run whose bytes went away.
    private func replaceOutput(of commandID: String) async {
        guard let stored = snapshot(commandID) else {
            turnLogger.warning(
                "run \(commandID, privacy: .public): a gap arrived with no stored record to replace from"
            )
            return
        }
        await send(
            .terminalUpdate(
                TerminalUpdate(
                    terminalId: TerminalId(rawValue: commandID),
                    output: .value(Self.output(of: stored)))))
    }

    /// Reports the run's exit: the presence of `exitStatus` marks the
    /// terminal exited, with neither an exit code nor a signal — the
    /// stream carries no code, and a soft-deadline kill has none. The
    /// final output replacement rides beside it when the store holds a
    /// record; without one the output honestly stays unchanged.
    ///
    /// - Parameter commandID: The run that ended.
    private func reportExit(of commandID: String) async {
        let output: PatchField<TerminalOutput>
        if let stored = snapshot(commandID) {
            output = .value(Self.output(of: stored))
        } else {
            output = .unchanged
        }
        await send(
            .terminalUpdate(
                TerminalUpdate(
                    terminalId: TerminalId(rawValue: commandID),
                    exitStatus: .value(TerminalExitStatus()),
                    output: output)))
    }
}

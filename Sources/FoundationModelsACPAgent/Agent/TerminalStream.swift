import Foundation
import FoundationModelsACP
import FoundationModelsMultitool
import Logging

/// The terminal display projection: the one mapping
/// from the host-owned `ShellOutputChunkStream` to the wire's
/// display-only terminal updates.
///
/// The identity rule: a shell run's `commandID` is its
/// `correlationID` and its `completionToken` — one string — and it maps
/// to the run's `terminalId`. The `toolCallId` of the run is the SDK
/// tool-call id that Router joined to the run, or the completion token
/// when no SDK call joined it (``RunCallJoinTable``, task ^9xk3xf4). Each
/// event kind maps to one wire shape:
///
/// - The first event of a run sends the `tool_call_update` whose
///   content is the `Terminal` reference, so the client can attach the
///   terminal to the call before any byte arrives. When the join of the
///   run is not known yet, the events of that run wait, in arrival order,
///   until the table writes its entry. The events of the other runs do not
///   wait.
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
/// each event out exactly once — run exactly one loop.
struct TerminalStream {
    /// The reader of a run's stored raw output, for the gap and
    /// completion replacements. The production reader is the same
    /// stream's `snapshot(for:)`.
    let snapshot: ShellSnapshotProvider

    /// The join of each run of the session to its SDK tool call, which the
    /// projection of each prompt writes. `nil` means that no projection
    /// writes joins: each announce then goes on the completion token at
    /// once.
    let runCallJoins: RunCallJoinTable?

    /// The sink every update of this projection goes to.
    let send: SessionUpdateSink

    /// The runs whose `Terminal` reference already went out. A run
    /// leaves the set at its completion marker, because no later event
    /// carries its `commandID`.
    private var announcedRuns: Set<String> = []

    /// The events of each run that waits for its entry in ``runCallJoins``,
    /// in arrival order, keyed by the `commandID` of the run.
    private var waitingEvents: [String: [ShellOutputEvent]] = [:]

    /// One input of the consumer loop.
    private enum Input: Sendable {
        /// A live shell event.
        case event(ShellOutputEvent)

        /// The table wrote the entry of the waiting run with this
        /// `commandID`.
        case joined(String)

        /// The shell output stream ended.
        case streamEnded
    }

    /// Makes a projection over `snapshot`, `runCallJoins` and `send`.
    ///
    /// - Parameters:
    ///   - snapshot: The reader of a run's stored raw output.
    ///   - runCallJoins: The join table of the session, or `nil` when no
    ///     projection writes joins.
    ///   - send: The sink every update goes to.
    init(
        snapshot: @escaping ShellSnapshotProvider,
        runCallJoins: RunCallJoinTable? = nil,
        send: @escaping SessionUpdateSink
    ) {
        self.snapshot = snapshot
        self.runCallJoins = runCallJoins
        self.send = send
    }

    /// Starts the one consumer loop over the host-owned stream.
    ///
    /// The task ends when the stream finishes — `finish()` at session
    /// teardown, or the stream's own deinit — and the session lifecycle
    /// keeps the handle so a teardown can cancel it.
    ///
    /// - Parameters:
    ///   - stream: The host-owned stream to consume. Its
    ///     `snapshot(for:)` backs the gap and completion replacements.
    ///   - runCallJoins: The join table of the session, or `nil` when no
    ///     projection writes joins.
    ///   - send: The sink every update goes to.
    /// - Returns: The running consumer task.
    @discardableResult
    static func start(
        over stream: ShellOutputChunkStream,
        runCallJoins: RunCallJoinTable? = nil,
        send: @escaping SessionUpdateSink
    ) -> Task<Void, Never> {
        Task {
            var projection = TerminalStream(
                snapshot: { commandID in stream.snapshot(for: commandID) },
                runCallJoins: runCallJoins,
                send: send)
            await projection.consume(stream)
        }
    }

    /// Consumes `events` to its end, projecting each one.
    ///
    /// One loop reads two inputs in one order: the live shell events, and
    /// the entries that ``runCallJoins`` writes for the waiting runs. Thus a
    /// run that waits for its entry stops only its own events. When the
    /// shell output stream ends, the loop continues until no run waits. A
    /// cancelled task stops the loop at once, and each run that still waits
    /// gets "no join" (``releaseWaitingRuns()``).
    ///
    /// - Parameter events: The live stream, usually a
    ///   `ShellOutputChunkStream`.
    mutating func consume<Events: AsyncSequence<ShellOutputEvent, Never> & Sendable>(
        _ events: Events
    ) async {
        let (inputs, continuation) = AsyncStream.makeStream(of: Input.self)
        runCallJoins?.observeJoins { commandID in
            continuation.yield(.joined(commandID))
        }
        let forwarder = Task {
            for await event in events {
                continuation.yield(.event(event))
            }
            continuation.yield(.streamEnded)
        }
        await handle(inputs)
        forwarder.cancel()
        runCallJoins?.observeJoins(nil)
        continuation.finish()
        await releaseWaitingRuns()
    }

    /// Handles each input until the shell output stream ended and no run
    /// waits, or until the task is cancelled.
    ///
    /// - Parameter inputs: The merged inputs of ``consume(_:)``.
    private mutating func handle(_ inputs: AsyncStream<Input>) async {
        var isStreamEnded = false
        for await input in inputs {
            switch input {
            case .event(let event):
                await project(event)
            case .joined(let commandID):
                await announceWaitingRun(commandID)
            case .streamEnded:
                isStreamEnded = true
            }
            if isStreamEnded && waitingEvents.isEmpty {
                return
            }
        }
    }

    /// Projects one live shell event to the wire. The event of a run that
    /// waits for its entry waits too, after the earlier events of its run.
    ///
    /// - Parameter event: The event to project.
    mutating func project(_ event: ShellOutputEvent) async {
        let commandID = event.commandID
        if waitingEvents[commandID] != nil {
            waitingEvents[commandID]?.append(event)
            return
        }
        if !announcedRuns.contains(commandID) {
            guard let toolCallId = announceToolCallId(for: commandID) else {
                waitingEvents[commandID] = [event]
                return
            }
            await announce(commandID, on: toolCallId)
        }
        await emit(event)
    }

    /// Sends the announce of a run that waited, on the id of its entry, and
    /// then each event of the run that waited, in arrival order.
    ///
    /// - Parameter commandID: The run whose entry the table wrote.
    private mutating func announceWaitingRun(_ commandID: String) async {
        guard let events = waitingEvents.removeValue(forKey: commandID) else {
            return
        }
        await announce(
            commandID, on: runCallJoins?.toolCallId(for: commandID) ?? ToolCallId(rawValue: commandID))
        for event in events {
            await emit(event)
        }
    }

    /// Writes "no join" for each run that still waits, and sends its events:
    /// the loop ended, so no entry comes to the loop after this point. A run
    /// whose entry the table wrote before the seal keeps that entry.
    private mutating func releaseWaitingRuns() async {
        for commandID in Array(waitingEvents.keys) {
            runCallJoins?.seal(commandID)
            await announceWaitingRun(commandID)
        }
    }

    /// Sends one live shell event of a run that is announced.
    ///
    /// - Parameter event: The event to send.
    private mutating func emit(_ event: ShellOutputEvent) async {
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
            ACPAgentTelemetry.logger(.promptExecution).debug(
                "The terminal stream does not know a shell output event.",
                metadata: [ACPAgentTelemetry.LogMetadataKey.toolCallId: "\(event.commandID)"])
        }
    }

    /// The `Terminal` content reference of one run, for the tool call
    /// that owns it. The settlement projection reuses it.
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
    /// `tool_call_update`, saying the call runs — the first update with
    /// an unseen id is the creation, and a creation must not leave
    /// `pending` in place: a creating update that omits `status` defaults
    /// to `pending`, and the client then shows a running call as queued.
    ///
    /// The update keys on the wire id that ``runCallJoins`` gives the run:
    /// the joined SDK id, or the `commandID` when no SDK call joined the
    /// run. The caller sends it only when the entry is final, so each run
    /// gets one update on its final id. The `Terminal` reference keeps the
    /// `commandID`.
    ///
    /// - Parameters:
    ///   - commandID: The run the event belongs to.
    ///   - toolCallId: The final wire id of the run.
    private mutating func announce(_ commandID: String, on toolCallId: ToolCallId) async {
        announcedRuns.insert(commandID)
        await send(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: toolCallId,
                    content: .value([Self.terminalItem(for: commandID)]),
                    status: .value(.inProgress))))
    }

    /// The final wire id of a run that has no announce yet, or `nil` when
    /// the run must wait for its entry in ``runCallJoins``. With no table,
    /// each run keeps its `commandID`.
    ///
    /// - Parameter commandID: The run.
    /// - Returns: The tool call id, or `nil` when the run waits.
    private func announceToolCallId(for commandID: String) -> ToolCallId? {
        guard let runCallJoins else {
            return ToolCallId(rawValue: commandID)
        }
        return runCallJoins.announceToolCallId(for: commandID)
    }

    /// Replaces the client's view of one run with the stored record: a
    /// gap said bytes went away, and the snapshot is the "replace" half
    /// of the stream's contract. A run the store never saw is logged;
    /// the client keeps its view until the completion replacement.
    ///
    /// - Parameter commandID: The run whose bytes went away.
    private func replaceOutput(of commandID: String) async {
        guard let stored = snapshot(commandID) else {
            ACPAgentTelemetry.logger(.promptExecution).warning(
                "A gap arrived, but no stored record can replace the output.",
                metadata: [ACPAgentTelemetry.LogMetadataKey.toolCallId: "\(commandID)"])
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

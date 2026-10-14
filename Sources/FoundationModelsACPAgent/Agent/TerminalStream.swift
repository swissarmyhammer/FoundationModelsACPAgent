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
///   run is not known yet, the run waits until the table writes its entry.
///   A waiting run keeps no bytes: it keeps only the fact that it has
///   output and that it exited (``WaitingRun``). At its release it sends
///   the one announce, then one replacement built from `snapshot(for:)`.
///   The events of the other runs do not wait.
/// - `.output(stream:bytes:)` becomes one `terminal_output_chunk`,
///   base64-encoded on its own. The bytes stay true: no UTF-8 decode
///   and no lossy text coercion touches them.
/// - `.gap(stream:droppedByteCount:)` becomes one `TerminalUpdate`
///   whose `output` is the authoritative replacement built from
///   `snapshot(for:)` — the ACP replace is made for a client that lost
///   bytes to backpressure.
/// - After a replacement, a chunk sends only the bytes past the end of
///   that replacement in its stream (``ShellRunByteLedger``). The upstream
///   queue can hold chunks whose bytes the replacement already has, and
///   no byte of a run goes on the wire two times.
/// - `.completed` becomes one `TerminalUpdate` whose `exitStatus` is
///   present with neither an exit code nor a signal: the presence marks
///   exited, which agrees with a soft-deadline kill, and the exit code
///   does not cross the module boundary on this stream. The final
///   output replacement rides beside it.
///
/// One value consumes one stream, because the upstream stream hands
/// each event out exactly once — run exactly one loop. The loop reads at
/// most one event ahead of what it sent (``ShellEventGate``), so the
/// pending-byte budget of the upstream stream stays in force.
struct TerminalStream {
    /// What a run that waits for its entry keeps: no bytes, only the facts
    /// that its release needs.
    struct WaitingRun {
        /// Whether an output or a gap event of the run came while it waited.
        private(set) var hasOutput = false

        /// Whether the completion marker of the run came while it waited.
        private(set) var hasExited = false

        /// Keeps the fact that one event of the run gives.
        ///
        /// - Parameter kind: The kind of the event.
        mutating func note(_ kind: ShellOutputEvent.Kind) {
            switch kind {
            case .output, .gap:
                hasOutput = true
            case .completed:
                hasExited = true
            @unknown default:
                // The upstream kind is not frozen: a new case gives no fact
                // that the release can use.
                break
            }
        }
    }

    /// The reader of a run's stored raw output, for the gap and
    /// completion replacements. The production reader is the same
    /// stream's `snapshot(for:)`.
    let snapshot: ShellSnapshotProvider

    /// The join of each run of the session to its SDK tool call, which the
    /// translator of the session projector writes. A table that no projector
    /// opened gives each run "no join" at once, so its announce goes on the
    /// completion token.
    let runCallJoins: RunCallJoinTable

    /// The sink every update of this projection goes to.
    let send: SessionUpdateSink

    /// Where the forwarder of ``consume(_:)`` waits: for the next shell
    /// event of the upstream stream, or for its turn after the loop took
    /// one event. A test reads these steps to prove that the forwarder
    /// reads no event ahead while the sink holds a send.
    enum ForwarderStep: Equatable, Sendable {
        /// The forwarder waits for the next shell event of the stream.
        case awaitingUpstream

        /// The forwarder handed one event over, and waits until the loop
        /// handled it.
        case awaitingTurn
    }

    /// Gets each step of the forwarder, in order, or `nil` to observe
    /// nothing. Only a test sets it.
    var forwarderObserver: (@Sendable (ForwarderStep) -> Void)?

    /// The runs whose `Terminal` reference already went out. A run
    /// leaves the set at its completion marker, because no later event
    /// carries its `commandID`.
    private var announcedRuns: Set<String> = []

    /// Each run that waits for its entry in ``runCallJoins``, keyed by the
    /// `commandID` of the run.
    private var waitingRuns: [String: WaitingRun] = [:]

    /// The byte offsets of each run that is not finished, keyed by the
    /// `commandID` of the run. A run leaves the table at its completion
    /// marker, because no later event carries its `commandID`.
    private var byteLedgers: [String: ShellRunByteLedger] = [:]

    /// One input of the consumer loop.
    private enum Input: Sendable {
        /// A live shell event. The forwarder reads the next one only after
        /// the loop handled this one.
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
    ///   - runCallJoins: The join table of the session. The default is a
    ///     table that no projector opens.
    ///   - send: The sink every update goes to.
    init(
        snapshot: @escaping ShellSnapshotProvider,
        runCallJoins: RunCallJoinTable = RunCallJoinTable(),
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
    ///   - runCallJoins: The join table of the session. The default is a
    ///     table that no projector opens.
    ///   - forwarderObserver: Gets each step of the forwarder, or `nil`
    ///     (the default) to observe nothing. Only a test gives it.
    ///   - send: The sink every update goes to.
    /// - Returns: The running consumer task.
    @discardableResult
    static func start(
        over stream: ShellOutputChunkStream,
        runCallJoins: RunCallJoinTable = RunCallJoinTable(),
        forwarderObserver: (@Sendable (ForwarderStep) -> Void)? = nil,
        send: @escaping SessionUpdateSink
    ) -> Task<Void, Never> {
        Task {
            var projection = TerminalStream(
                snapshot: { commandID in stream.snapshot(for: commandID) },
                runCallJoins: runCallJoins,
                send: send)
            projection.forwarderObserver = forwarderObserver
            await projection.consume(stream)
        }
    }

    /// Consumes `events` to its end, projecting each one.
    ///
    /// One loop reads two inputs in one order: the live shell events, and
    /// the entries that ``runCallJoins`` writes for the waiting runs. Thus a
    /// run that waits for its entry stops only itself. The forwarder hands
    /// over one shell event at a time, and reads the next one only after the
    /// loop handled it (``ShellEventGate``). When the shell output stream
    /// ends, the loop continues until no run waits. A cancelled task stops
    /// the loop at once, and each run that still waits gets "no join"
    /// (``releaseWaitingRuns()``).
    ///
    /// - Parameter events: The live stream, usually a
    ///   `ShellOutputChunkStream`.
    mutating func consume<Events: AsyncSequence<ShellOutputEvent, Never> & Sendable>(
        _ events: Events
    ) async {
        let (inputs, continuation) = AsyncStream.makeStream(of: Input.self)
        let gate = ShellEventGate()
        runCallJoins.observeJoins { commandID in
            continuation.yield(.joined(commandID))
        }
        let observe = forwarderObserver ?? { _ in }
        let forwarder = Task {
            var iterator = events.makeAsyncIterator()
            while true {
                observe(.awaitingUpstream)
                guard let event = await iterator.next(isolation: nil) else {
                    break
                }
                continuation.yield(.event(event))
                observe(.awaitingTurn)
                guard await gate.waitForTurn() else {
                    return
                }
            }
            continuation.yield(.streamEnded)
        }
        await handle(inputs, gate: gate)
        gate.close()
        forwarder.cancel()
        runCallJoins.observeJoins(nil)
        continuation.finish()
        await releaseWaitingRuns()
    }

    /// Handles each input until the shell output stream ended and no run
    /// waits, or until the task is cancelled.
    ///
    /// - Parameters:
    ///   - inputs: The merged inputs of ``consume(_:)``.
    ///   - gate: The handoff that gives the forwarder its turn after each
    ///     shell event.
    private mutating func handle(_ inputs: AsyncStream<Input>, gate: ShellEventGate) async {
        var isStreamEnded = false
        for await input in inputs {
            switch input {
            case .event(let event):
                await project(event)
                gate.pass()
            case .joined(let commandID):
                await announceWaitingRun(commandID)
            case .streamEnded:
                isStreamEnded = true
            }
            if isStreamEnded && waitingRuns.isEmpty {
                return
            }
        }
    }

    /// Projects one live shell event to the wire. The event of a run that
    /// waits for its entry sends nothing: the run keeps only the fact that
    /// the event gives (``WaitingRun``). Each event moves the byte offsets
    /// of its run, also when it sends nothing (``ShellRunByteLedger``).
    ///
    /// - Parameter event: The event to project.
    mutating func project(_ event: ShellOutputEvent) async {
        let commandID = event.commandID
        let newBytes = byteLedgers[commandID, default: ShellRunByteLedger()].advance(past: event.kind)
        if waitingRuns[commandID] != nil {
            waitingRuns[commandID]?.note(event.kind)
            return
        }
        if !announcedRuns.contains(commandID) {
            guard let toolCallId = runCallJoins.announceToolCallId(for: commandID) else {
                var waitingRun = WaitingRun()
                waitingRun.note(event.kind)
                waitingRuns[commandID] = waitingRun
                return
            }
            await announce(commandID, on: toolCallId)
        }
        await emit(event, newBytes: newBytes)
    }

    /// Releases a run that waited: the one announce on the id of its entry,
    /// then one replacement built from the stored record. A run that exited
    /// while it waited sends the exit report, which carries the replacement.
    /// Each later event of the run goes direct.
    ///
    /// - Parameter commandID: The run whose entry the table wrote.
    private mutating func announceWaitingRun(_ commandID: String) async {
        guard let waitingRun = waitingRuns.removeValue(forKey: commandID) else {
            assertionFailure("no waiting run for \(commandID)")
            ACPAgentTelemetry.logger(.promptExecution).warning(
                "A joined run had no waiting events; nothing is sent.",
                metadata: [ACPAgentTelemetry.LogMetadataKey.toolCallId: "\(commandID)"])
            return
        }
        await announce(commandID, on: runCallJoins.toolCallId(for: commandID))
        if waitingRun.hasExited {
            await reportExit(of: commandID)
        } else if waitingRun.hasOutput {
            await replaceOutput(of: commandID)
        }
    }

    /// Writes "no join" for each run that still waits, and releases it: the
    /// loop ended, so no entry comes to the loop after this point. A run
    /// whose entry the table wrote before the seal keeps that entry.
    private mutating func releaseWaitingRuns() async {
        for commandID in Array(waitingRuns.keys) {
            runCallJoins.seal(commandID)
            await announceWaitingRun(commandID)
        }
    }

    /// Sends one live shell event of a run that is announced.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - newBytes: The bytes of an output event that the client view does
    ///     not hold yet. An output event whose bytes the last replacement
    ///     holds sends no chunk.
    private mutating func emit(_ event: ShellOutputEvent, newBytes: ArraySlice<UInt8>) async {
        switch event.kind {
        case .output:
            guard !newBytes.isEmpty else {
                return
            }
            await send(
                .terminalOutputChunk(
                    TerminalOutputChunk(
                        data: Data(newBytes).base64EncodedString(),
                        terminalId: TerminalId(rawValue: event.commandID))))
        case .gap:
            await replaceOutput(of: event.commandID)
        case .completed:
            await reportExit(of: event.commandID)
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

    /// Replaces the client's view of one run with the stored record: a
    /// gap said bytes went away, and the snapshot is the "replace" half
    /// of the stream's contract. A run the store never saw is logged;
    /// the client keeps its view until the completion replacement. The
    /// ledger of the run records where the replacement ends, so a later
    /// chunk sends no byte that the replacement holds.
    ///
    /// - Parameter commandID: The run whose bytes went away.
    private mutating func replaceOutput(of commandID: String) async {
        guard let stored = snapshot(commandID) else {
            ACPAgentTelemetry.logger(.promptExecution).warning(
                "A gap arrived, but no stored record can replace the output.",
                metadata: [ACPAgentTelemetry.LogMetadataKey.toolCallId: "\(commandID)"])
            return
        }
        byteLedgers[commandID, default: ShellRunByteLedger()].recordReplacement(by: stored)
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
    /// record; without one the output honestly stays unchanged. No later
    /// event carries the `commandID` of the run, so the run leaves the
    /// announced set and the ledger table.
    ///
    /// - Parameter commandID: The run that ended.
    private mutating func reportExit(of commandID: String) async {
        announcedRuns.remove(commandID)
        byteLedgers.removeValue(forKey: commandID)
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

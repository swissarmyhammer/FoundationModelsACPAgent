import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Synchronization
import Testing

@testable import FoundationModelsACPAgent
// The producer side of `ShellOutputChunkStream` (`send` and `complete`) is
// internal: the shell runner owns it. The back-pressure test drives it this
// way, as a debug build compiles the package with testing enabled.
@testable import FoundationModelsMultitool

/// A sink that holds its first send until the test releases it: a client
/// that reads slowly.
private actor HeldSink {
    /// The recorder of each update that came to the sink.
    let recorder = SinkRecorder()

    /// Whether the sink still holds its first send.
    private var isHolding = true

    /// The first send, while the sink holds it.
    private var heldSend: CheckedContinuation<Void, Never>?

    /// The test that waits until the sink holds a send.
    private var holdWaiter: CheckedContinuation<Void, Never>?

    /// Records `update`, and holds the first send until ``release()``.
    ///
    /// - Parameter update: The sent update.
    func receive(_ update: SessionUpdate) async {
        await recorder.append(update)
        guard isHolding, heldSend == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            heldSend = continuation
            holdWaiter?.resume()
            holdWaiter = nil
        }
    }

    /// Returns when the sink holds its first send.
    func waitUntilHolding() async {
        guard heldSend == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            holdWaiter = continuation
        }
    }

    /// Releases the held send. Each later send goes through at once.
    func release() {
        isHolding = false
        heldSend?.resume()
        heldSend = nil
    }
}

/// A snapshot store whose stored output grows between two calls, as the
/// store of a live run does. Each call gives the next snapshot of the list,
/// and the last snapshot after the list ends.
private final class SnapshotSequence: Sendable {
    /// The snapshots, in call order.
    private let snapshots: [ShellOutputSnapshot]

    /// The count of calls that came before the next call.
    private let callCount = Mutex(0)

    /// Makes a store that gives `snapshots` in order.
    ///
    /// - Parameter snapshots: The snapshots, in call order. The list is not
    ///   empty.
    init(_ snapshots: [ShellOutputSnapshot]) {
        precondition(!snapshots.isEmpty, "a snapshot sequence needs a snapshot")
        self.snapshots = snapshots
    }

    /// Gives the snapshot of this call, and moves to the next one.
    ///
    /// - Returns: The snapshot of this call, or the last snapshot after the
    ///   list ends.
    func nextSnapshot() -> ShellOutputSnapshot {
        let call = callCount.withLock { count in
            defer { count += 1 }
            return count
        }
        return snapshots[min(call, snapshots.count - 1)]
    }
}

/// The terminal display stream: the shell capability's
/// live bytes ride `terminal_output_chunk` updates, the tool call
/// carries a `Terminal` content reference, a gap heals through a
/// `TerminalUpdate.output` replacement built from `snapshot(for:)`, and
/// the completion marker reports the exit through
/// `TerminalUpdate.exitStatus`.
@Suite struct TerminalStreamTests {
    // MARK: - Constants

    /// The completion token of the scripted run. It is the run's
    /// `commandID`, its `correlationID`, and its `terminalId`.
    private static let completionToken = "01TERMINALRUNTOKEN00000000"

    /// Two bytes that are not valid UTF-8, so a lossy text decode would
    /// be visible in the reassembly.
    private static let invalidUTF8Bytes: [UInt8] = [0x80, 0xFF]

    /// The byte count the scripted gap event reports as dropped.
    private static let scriptedDroppedByteCount = 9

    /// The command of the end-to-end run. `printf` writes the octal
    /// escapes `\200` and `\377` — the two ``invalidUTF8Bytes`` — between
    /// two plain words, so the reassembly proves the bytes stay true.
    private static let fixtureCommand = #"printf 'plain\200\377bytes'"#

    /// The exact bytes ``fixtureCommand`` writes to stdout.
    private static let fixtureBytes =
        Array("plain".utf8) + invalidUTF8Bytes + Array("bytes".utf8)

    // MARK: - Fixtures

    /// A throwaway directory under `/private/tmp`, labeled with this
    /// suite's name and the directory's role.
    ///
    /// - Parameter name: The directory's role.
    /// - Returns: The created directory.
    private static func makeResolvedDirectory(named name: String) -> URL {
        FoundationModelsACPAgentTestSupport.makeResolvedDirectory(
            label: "TerminalStreamTests-\(name)")
    }

    /// Projects `events` through one terminal projection and returns
    /// every update it sent, in order.
    ///
    /// - Parameters:
    ///   - events: The shell output events, in order.
    ///   - snapshot: The reader of a run's stored output; the default
    ///     finds no run.
    /// - Returns: The sent updates, in order.
    private static func project(
        _ events: [ShellOutputEvent],
        snapshot: @escaping ShellSnapshotProvider = { _ in nil }
    ) async -> [SessionUpdate] {
        let recorder = SinkRecorder()
        var projection = TerminalStream(snapshot: snapshot) { update in
            await recorder.append(update)
        }
        for event in events {
            await projection.project(event)
        }
        return await recorder.updates
    }

    /// One output event of the scripted run.
    ///
    /// - Parameters:
    ///   - bytes: The bytes the child wrote.
    ///   - stream: The stream it wrote them to.
    /// - Returns: The event.
    private static func makeOutputEvent(
        bytes: [UInt8], stream: ShellOutputStream = .stdout
    ) -> ShellOutputEvent {
        ShellOutputEvent(
            commandID: completionToken, kind: .output(stream: stream, bytes: bytes))
    }

    /// The stored raw output of one stream, complete and clean.
    ///
    /// - Parameter bytes: The stored bytes.
    /// - Returns: The raw output.
    private static func makeRawOutput(bytes: [UInt8]) -> ShellRawOutput {
        ShellRawOutput(
            bytes: bytes, binaryDetected: false, truncated: false,
            storedByteCount: bytes.count)
    }

    /// A snapshot provider that answers `snapshot` for the scripted run
    /// and nothing for any other token.
    ///
    /// - Parameter snapshot: The snapshot of the scripted run.
    /// - Returns: The provider.
    private static func provider(
        of snapshot: ShellOutputSnapshot
    ) -> ShellSnapshotProvider {
        { commandID in commandID == completionToken ? snapshot : nil }
    }

    // MARK: - Readers

    /// Reassembles the bytes of every chunk in the sequence, in order.
    ///
    /// - Parameter updates: The sent updates.
    /// - Returns: The concatenated decoded bytes.
    /// - Throws: The `#require` failure when a chunk is not base64.
    private static func reassembledBytes(in updates: [SessionUpdate]) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for chunk in terminalChunks(in: updates) {
            let data = try #require(Data(base64Encoded: chunk.data))
            bytes += Array(data)
        }
        return bytes
    }

    // MARK: - The terminal reference

    /// The first event of a run sends one `tool_call_update` whose
    /// content is the `Terminal` reference, keyed by the run's
    /// `commandID`, and says the call runs. A later event of the same
    /// run announces nothing again.
    @Test func theFirstEventOfARunAnnouncesTheTerminalReferenceOnce() async throws {
        let updates = await Self.project([
            Self.makeOutputEvent(bytes: Array("one".utf8)),
            Self.makeOutputEvent(bytes: Array("two".utf8)),
        ])

        let calls = toolCallUpdates(in: updates)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.toolCallId.rawValue == Self.completionToken)
        #expect(call.status == .value(.inProgress))
        #expect(terminalIds(in: call.content) == [Self.completionToken])
    }

    // MARK: - The chunk stream

    /// An output event becomes one `terminal_output_chunk` whose data
    /// decodes to the child's bytes exactly — invalid UTF-8 included,
    /// never coerced to text.
    @Test func anOutputEventCarriesItsBytesBase64EncodedAndByteTrue() async throws {
        let bytes = Array("build ok ".utf8) + Self.invalidUTF8Bytes

        let updates = await Self.project([Self.makeOutputEvent(bytes: bytes)])

        let chunk = try #require(terminalChunks(in: updates).first)
        #expect(chunk.terminalId.rawValue == Self.completionToken)
        let data = try #require(Data(base64Encoded: chunk.data))
        #expect(Array(data) == bytes)
    }

    /// The chunks of a run reassemble to the run's output byte for
    /// byte, in delivery order, across both streams.
    @Test func theChunksOfARunReassembleByteForByte() async throws {
        let first = Array("out ".utf8) + Self.invalidUTF8Bytes
        let second = Array("err".utf8)
        let third = Array(" done".utf8)

        let updates = await Self.project([
            Self.makeOutputEvent(bytes: first),
            Self.makeOutputEvent(bytes: second, stream: .stderr),
            Self.makeOutputEvent(bytes: third),
        ])

        #expect(try Self.reassembledBytes(in: updates) == first + second + third)
    }

    // MARK: - The gap replacement

    /// A gap event replaces the client's view with the authoritative
    /// stored record: one `TerminalUpdate` whose output is the stored
    /// stdout then the stored stderr, base64-encoded, with no exit
    /// claim.
    @Test func aGapEventReplacesTheOutputFromTheStoredSnapshot() async throws {
        let stdout = Array("kept ".utf8) + Self.invalidUTF8Bytes
        let stderr = Array("warn".utf8)
        let snapshot = ShellOutputSnapshot(
            stdout: Self.makeRawOutput(bytes: stdout),
            stderr: Self.makeRawOutput(bytes: stderr))

        let updates = await Self.project(
            [
                ShellOutputEvent(
                    commandID: Self.completionToken,
                    kind: .gap(stream: .stdout, droppedByteCount: Self.scriptedDroppedByteCount))
            ],
            snapshot: Self.provider(of: snapshot))

        let terminal = try #require(terminalUpdates(in: updates).first)
        #expect(terminal.terminalId.rawValue == Self.completionToken)
        #expect(terminal.exitStatus == .unchanged)
        let output = try #require(
            patchValue(terminal.output),
            "expected an output replacement, got \(terminal.output)")
        let data = try #require(Data(base64Encoded: output.data))
        #expect(Array(data) == stdout + stderr)
    }

    // MARK: - The bytes behind a replacement

    /// The first chunk of the replacement tests. Each chunk has its own
    /// letters, so a byte that goes on the wire two times is visible.
    private static let firstChunk = Array("AAAA".utf8)

    /// The second chunk of the replacement tests.
    private static let secondChunk = Array("BBBB".utf8)

    /// The third chunk of the replacement tests.
    private static let thirdChunk = Array("CCCC".utf8)

    /// The fourth chunk of the replacement tests.
    private static let fourthChunk = Array("DDDD".utf8)

    /// The fifth chunk of the replacement tests.
    private static let fifthChunk = Array("EEEE".utf8)

    /// The end offset of the third chunk in the stdout stream: the byte count
    /// of the first three chunks together.
    private static let byteCountThroughTheThirdChunk = firstChunk.count + secondChunk.count + thirdChunk.count

    /// One gap event of the scripted run.
    ///
    /// - Parameters:
    ///   - droppedByteCount: The bytes that went away upstream.
    ///   - stream: The stream they went away from.
    /// - Returns: The event.
    private static func makeGapEvent(
        droppedByteCount: Int, stream: ShellOutputStream = .stdout
    ) -> ShellOutputEvent {
        ShellOutputEvent(
            commandID: completionToken,
            kind: .gap(stream: stream, droppedByteCount: droppedByteCount))
    }

    /// A snapshot of the scripted run whose stdout is `stdout` and whose
    /// stderr is `stderr`, both complete and clean.
    ///
    /// - Parameters:
    ///   - stdout: The stored stdout bytes.
    ///   - stderr: The stored stderr bytes.
    /// - Returns: The snapshot.
    private static func makeSnapshot(stdout: [UInt8], stderr: [UInt8] = []) -> ShellOutputSnapshot {
        ShellOutputSnapshot(stdout: makeRawOutput(bytes: stdout), stderr: makeRawOutput(bytes: stderr))
    }

    /// A snapshot of the scripted run whose stdout capture is truncated: the
    /// store holds `stored`, and `arrivedByteCount` bytes of stdout arrived
    /// at the store. The stderr capture is empty.
    ///
    /// - Parameters:
    ///   - stored: The stdout bytes that the store holds.
    ///   - arrivedByteCount: The stdout bytes that arrived at the store, the
    ///     dropped bytes included.
    /// - Returns: The snapshot.
    private static func makeTruncatedSnapshot(stored: [UInt8], arrivedByteCount: Int) -> ShellOutputSnapshot {
        ShellOutputSnapshot(
            stdout: ShellRawOutput(
                bytes: stored, binaryDetected: false, truncated: true,
                storedByteCount: stored.count, arrivedByteCount: arrivedByteCount),
            stderr: makeRawOutput(bytes: []))
    }

    /// A snapshot provider that answers the next snapshot of `store` for the
    /// scripted run and nothing for any other token.
    ///
    /// - Parameter store: The snapshots of the scripted run, in call order.
    /// - Returns: The provider.
    private static func provider(of store: SnapshotSequence) -> ShellSnapshotProvider {
        { commandID in commandID == completionToken ? store.nextSnapshot() : nil }
    }

    /// Decodes the base64 data of one update.
    ///
    /// - Parameter data: The base64 text.
    /// - Returns: The decoded bytes.
    /// - Throws: The `#require` failure when the text is not base64.
    private static func decodedBytes(_ data: String) throws -> [UInt8] {
        Array(try #require(Data(base64Encoded: data)))
    }

    /// Replays the updates of the scripted run as a client does: a
    /// replacement puts its bytes in place of the view, and a chunk appends
    /// its bytes to the view.
    ///
    /// - Parameter sent: The sent updates.
    /// - Returns: The bytes that the client shows for the run.
    /// - Throws: The `#require` failure when an update is not base64.
    private static func clientView(in sent: [SessionUpdate]) throws -> [UInt8] {
        var view: [UInt8] = []
        for update in updates(of: completionToken, in: sent) {
            switch update {
            case .terminalOutputChunk(let chunk):
                view += try decodedBytes(chunk.data)
            case .terminalUpdate(let terminal):
                if let output = patchValue(terminal.output) {
                    view = try decodedBytes(output.data)
                }
            default:
                break
            }
        }
        return view
    }

    /// A chunk that the upstream queue held behind a gap is in the gap
    /// replacement already, so it sends no byte. A chunk past the
    /// replacement goes on the wire whole, and the client view is the
    /// output of the run byte for byte.
    @Test func aChunkQueuedBehindAGapReplacementSendsNoByteAgain() async throws {
        let stored = Self.firstChunk + Self.secondChunk + Self.thirdChunk

        let updates = await Self.project(
            [
                Self.makeOutputEvent(bytes: Self.firstChunk),
                Self.makeGapEvent(droppedByteCount: Self.secondChunk.count),
                Self.makeOutputEvent(bytes: Self.thirdChunk),
                Self.makeOutputEvent(bytes: Self.fourthChunk),
            ],
            snapshot: Self.provider(of: Self.makeSnapshot(stdout: stored)))

        #expect(try Self.reassembledBytes(in: updates) == Self.firstChunk + Self.fourthChunk)
        #expect(try Self.clientView(in: updates) == stored + Self.fourthChunk)
    }

    /// Each stream of a run keeps its own byte offset. The replacement holds
    /// the queued stdout chunk but not the stderr chunk after it. Thus the
    /// stderr chunk goes on the wire and the stdout chunk is dropped. A
    /// ledger with one offset for the whole run (stdout and stderr added)
    /// gets both wrong: it drops the stderr chunk and sends the stdout chunk.
    @Test func eachStreamDropsTheBytesThatTheReplacementHolds() async throws {
        let firstStderr = Array("err1".utf8)
        let lateStderr = Array("err2".utf8)
        let stdout = Self.firstChunk + Self.secondChunk + Self.thirdChunk

        let updates = await Self.project(
            [
                Self.makeOutputEvent(bytes: Self.firstChunk),
                Self.makeOutputEvent(bytes: firstStderr, stream: .stderr),
                Self.makeGapEvent(droppedByteCount: Self.secondChunk.count),
                Self.makeOutputEvent(bytes: lateStderr, stream: .stderr),
                Self.makeOutputEvent(bytes: Self.thirdChunk),
            ],
            snapshot: Self.provider(of: Self.makeSnapshot(stdout: stdout, stderr: firstStderr)))

        #expect(try Self.reassembledBytes(in: updates) == Self.firstChunk + firstStderr + lateStderr)
        #expect(try Self.clientView(in: updates) == stdout + firstStderr + lateStderr)
    }

    /// A chunk that crosses the end of the replacement sends only the bytes
    /// past that end.
    @Test func aChunkThatCrossesTheReplacementSendsOnlyItsNewBytes() async throws {
        let stored = Self.firstChunk + Self.secondChunk

        let updates = await Self.project(
            [
                Self.makeGapEvent(droppedByteCount: Self.firstChunk.count),
                Self.makeOutputEvent(bytes: Self.secondChunk + Self.thirdChunk),
            ],
            snapshot: Self.provider(of: Self.makeSnapshot(stdout: stored)))

        #expect(try Self.reassembledBytes(in: updates) == Self.thirdChunk)
        #expect(try Self.clientView(in: updates) == stored + Self.thirdChunk)
    }

    /// A truncated snapshot is not a prefix of the output, but its arrived
    /// byte count is the end offset of the stream. The queued chunk that
    /// arrived before the snapshot sends no byte, and the chunk after it goes
    /// on the wire. Thus the live view of the run continues.
    @Test func aTruncatedReplacementSendsTheChunksPastItsArrivedBytes() async throws {
        let truncated = Self.makeTruncatedSnapshot(
            stored: Self.firstChunk, arrivedByteCount: Self.byteCountThroughTheThirdChunk)

        let updates = await Self.project(
            [
                Self.makeOutputEvent(bytes: Self.firstChunk),
                Self.makeGapEvent(droppedByteCount: Self.secondChunk.count),
                Self.makeOutputEvent(bytes: Self.thirdChunk),
                Self.makeOutputEvent(bytes: Self.fourthChunk),
            ],
            snapshot: Self.provider(of: truncated))

        #expect(try Self.reassembledBytes(in: updates) == Self.firstChunk + Self.fourthChunk)
        #expect(try Self.clientView(in: updates) == Self.firstChunk + Self.fourthChunk)
    }

    /// The bytes of the fourth chunk that arrived at the store before the
    /// first snapshot of the straddle test. The other bytes of that chunk
    /// arrived after it.
    private static let fourthChunkBytesBeforeTheFirstSnapshot = 2

    /// A gap stands before the next delivered event of its stream. Thus a gap
    /// for bytes that went away before a snapshot can arrive after that
    /// snapshot, and one gap can cover bytes on the two sides of it. The gap
    /// only moves the event offset of the stream forward. The queued chunk
    /// that the first snapshot holds sends no byte, and the chunk after the
    /// straddling gap goes on the wire whole.
    @Test func aGapThatStraddlesASnapshotMovesTheOffsetPastIt() async throws {
        let firstSnapshotEnd = Self.byteCountThroughTheThirdChunk + Self.fourthChunkBytesBeforeTheFirstSnapshot
        let secondSnapshotEnd = Self.byteCountThroughTheThirdChunk + Self.fourthChunk.count
        let store = SnapshotSequence([
            Self.makeTruncatedSnapshot(stored: Self.firstChunk, arrivedByteCount: firstSnapshotEnd),
            Self.makeTruncatedSnapshot(stored: Self.firstChunk, arrivedByteCount: secondSnapshotEnd),
        ])

        let updates = await Self.project(
            [
                Self.makeOutputEvent(bytes: Self.firstChunk),
                Self.makeGapEvent(droppedByteCount: Self.secondChunk.count),
                Self.makeOutputEvent(bytes: Self.thirdChunk),
                Self.makeGapEvent(droppedByteCount: Self.fourthChunk.count),
                Self.makeOutputEvent(bytes: Self.fifthChunk),
            ],
            snapshot: Self.provider(of: store))

        #expect(try Self.reassembledBytes(in: updates) == Self.firstChunk + Self.fifthChunk)
        #expect(try Self.clientView(in: updates) == Self.firstChunk + Self.fifthChunk)
    }

    // MARK: - The exit status

    /// The completion marker sends one `TerminalUpdate` whose exit
    /// status is present with neither an exit code nor a signal — the
    /// presence marks exited, which is what a soft-deadline kill can
    /// honestly say — beside the authoritative output replacement.
    @Test func aCompletedMarkerReportsExitedWithNeitherValueKnown() async throws {
        let stdout = Array("all".utf8)
        let snapshot = ShellOutputSnapshot(
            stdout: Self.makeRawOutput(bytes: stdout),
            stderr: Self.makeRawOutput(bytes: []))

        let updates = await Self.project(
            [ShellOutputEvent(commandID: Self.completionToken, kind: .completed)],
            snapshot: Self.provider(of: snapshot))

        let terminal = try #require(terminalUpdates(in: updates).first)
        #expect(terminal.exitStatus == .value(TerminalExitStatus()))
        let output = try #require(
            patchValue(terminal.output),
            "expected an output replacement, got \(terminal.output)")
        let data = try #require(Data(base64Encoded: output.data))
        #expect(Array(data) == stdout)
    }

    /// A completion marker with no stored record still marks the
    /// terminal exited; the output stays unchanged rather than lying
    /// with an empty replacement.
    @Test func aCompletedMarkerWithoutASnapshotStillReportsExited() async throws {
        let updates = await Self.project([
            ShellOutputEvent(commandID: Self.completionToken, kind: .completed)
        ])

        let terminal = try #require(terminalUpdates(in: updates).first)
        #expect(terminal.exitStatus == .value(TerminalExitStatus()))
        #expect(terminal.output == .unchanged)
    }

    /// The projection consumes a stream to its end: the reference, the
    /// chunk, and the exit update arrive in order.
    @Test func theProjectionConsumesAStreamToItsEnd() async {
        let recorder = SinkRecorder()
        let (stream, continuation) = AsyncStream<ShellOutputEvent>.makeStream()
        continuation.yield(Self.makeOutputEvent(bytes: Array("line\n".utf8)))
        continuation.yield(
            ShellOutputEvent(commandID: Self.completionToken, kind: .completed))
        continuation.finish()

        var projection = TerminalStream(snapshot: { _ in nil }) { update in
            await recorder.append(update)
        }
        await projection.consume(stream)
        let updates = await recorder.updates

        #expect(updates.map(\.kind) == [.toolCallUpdate, .terminalOutputChunk, .terminalUpdate])
    }

    // MARK: - The upstream budget

    /// The pending-byte budget of the upstream stream in the back-pressure
    /// test: one chunk of ``budgetChunk`` fills it.
    private static let smallBudget = 8

    /// One chunk of the back-pressure test. It fills ``smallBudget``.
    private static let budgetChunk = Array("12345678".utf8)

    /// The count of chunks that the producer sends while the sink holds its
    /// first send: one fills the budget, and each later one goes over it.
    private static let overBudgetChunkCount = 3

    /// The cap of the store behind `snapshot(for:)` in the back-pressure
    /// test. It holds each chunk.
    private static let storeCap = 1_024

    /// The time the producer gives a reader that reads ahead to take each
    /// chunk. A reader that reads ahead takes each chunk in this time, and
    /// then no gap occurs.
    private static let readAheadWindow: Duration = .milliseconds(50)

    /// The upstream budget stays in force when the client reads slowly: the
    /// terminal stream takes one event at a time, and takes the next one only
    /// after it sent the earlier one. Thus the bytes over the budget go away
    /// upstream, and the gap event replaces them from the stored record. A
    /// reader that read ahead would keep the bytes in its own memory, and no
    /// gap would occur.
    @Test(.timeLimit(.minutes(1)))
    func aSlowSinkKeepsTheUpstreamBudgetAndGetsAGap() async throws {
        let upstream = ShellOutputChunkStream(maxPendingBytes: Self.smallBudget)
        let sink = HeldSink()
        let reader = TerminalStream.start(over: upstream) { update in
            await sink.receive(update)
        }
        Self.sendBudgetChunk(to: upstream)
        await sink.waitUntilHolding()
        for _ in 0..<Self.overBudgetChunkCount {
            Self.sendBudgetChunk(to: upstream)
            try await Task.sleep(for: Self.readAheadWindow)
        }
        upstream.complete(commandID: Self.completionToken)
        await sink.release()

        let updates = await sink.recorder.updates { updates in
            terminalUpdates(in: updates).contains { $0.exitStatus != .unchanged }
        }
        upstream.finish()
        await reader.value

        let gapReplacements = terminalUpdates(in: updates).filter { terminal in
            terminal.exitStatus == .unchanged && patchValue(terminal.output) != nil
        }
        #expect(gapReplacements.count == 1)
    }

    /// Sends one ``budgetChunk`` of the scripted run to `upstream`.
    ///
    /// - Parameter upstream: The host-owned stream.
    private static func sendBudgetChunk(to upstream: ShellOutputChunkStream) {
        upstream.send(commandID: completionToken, from: .stdout, bytes: budgetChunk, maxSize: storeCap)
    }

    // MARK: - The release of a waiting run

    /// The completion token of the run that has its entry from the start, in
    /// the release test.
    private static let joinedRunToken = "01TERMINALJOINEDRUN0000000"

    /// The SDK tool-call id of ``joinedRunToken``.
    private static let joinedSdkCallId = "call-terminal-joined"

    /// A run that waits for its entry keeps no output bytes. At its release
    /// it sends one announce and one update with the replacement built from
    /// the stored record, and no chunk. The run ended while it waited, so the
    /// same update also marks the exit.
    @Test(.timeLimit(.minutes(1)))
    func aWaitingRunSendsOneSnapshotReplacementAtItsRelease() async throws {
        let stored = Array("one two".utf8)
        let snapshot = ShellOutputSnapshot(
            stdout: Self.makeRawOutput(bytes: stored), stderr: Self.makeRawOutput(bytes: []))
        let table = RunCallJoinTable()
        table.openPrompt()
        table.record(toolCallID: Self.joinedSdkCallId, for: Self.joinedRunToken)
        let recorder = SinkRecorder()
        let (events, input) = AsyncStream<ShellOutputEvent>.makeStream()
        let reader = Task {
            var projection = TerminalStream(snapshot: Self.provider(of: snapshot), runCallJoins: table) { update in
                await recorder.append(update)
            }
            await projection.consume(events)
        }
        input.yield(Self.makeOutputEvent(bytes: Array("one ".utf8)))
        input.yield(Self.makeOutputEvent(bytes: Array("two".utf8)))
        input.yield(ShellOutputEvent(commandID: Self.completionToken, kind: .completed))
        input.yield(
            ShellOutputEvent(commandID: Self.joinedRunToken, kind: .output(stream: .stdout, bytes: stored)))
        _ = await recorder.updates { updates in
            terminalChunks(in: updates).contains { $0.terminalId.rawValue == Self.joinedRunToken }
        }

        table.record(toolCallID: nil, for: Self.completionToken)
        let updates = await recorder.updates { updates in
            terminalUpdates(in: updates).contains { terminal in
                terminal.terminalId.rawValue == Self.completionToken && terminal.exitStatus != .unchanged
            }
        }
        input.finish()
        await reader.value

        let runUpdates = Self.updates(of: Self.completionToken, in: updates)
        #expect(runUpdates.map(\.kind) == [.toolCallUpdate, .terminalUpdate])
        let replacement = try #require(terminalUpdates(in: runUpdates).first)
        #expect(replacement.exitStatus == .value(TerminalExitStatus()))
        let output = try #require(patchValue(replacement.output))
        #expect(Data(base64Encoded: output.data).map(Array.init) == stored)
    }

    /// A chunk that the upstream queue held behind the release of a waiting
    /// run is in the release replacement already, so it sends no byte. A
    /// chunk past the replacement goes on the wire whole, and the client
    /// view is the output of the run byte for byte.
    @Test(.timeLimit(.minutes(1)))
    func aChunkQueuedBehindAWaitingRunReleaseSendsNoByteAgain() async throws {
        let stored = Self.firstChunk + Self.secondChunk
        let table = RunCallJoinTable()
        table.openPrompt()
        table.record(toolCallID: Self.joinedSdkCallId, for: Self.joinedRunToken)
        let recorder = SinkRecorder()
        let (events, input) = AsyncStream<ShellOutputEvent>.makeStream()
        let reader = Task {
            var projection = TerminalStream(
                snapshot: Self.provider(of: Self.makeSnapshot(stdout: stored)), runCallJoins: table
            ) { update in
                await recorder.append(update)
            }
            await projection.consume(events)
        }
        input.yield(Self.makeOutputEvent(bytes: Self.firstChunk))
        input.yield(
            ShellOutputEvent(
                commandID: Self.joinedRunToken, kind: .output(stream: .stdout, bytes: Self.firstChunk)))
        _ = await recorder.updates { updates in
            terminalChunks(in: updates).contains { $0.terminalId.rawValue == Self.joinedRunToken }
        }

        table.record(toolCallID: nil, for: Self.completionToken)
        _ = await recorder.updates { updates in
            terminalUpdates(in: updates).contains { $0.terminalId.rawValue == Self.completionToken }
        }
        input.yield(Self.makeOutputEvent(bytes: Self.secondChunk))
        input.yield(Self.makeOutputEvent(bytes: Self.thirdChunk))
        input.finish()
        await reader.value
        let updates = await recorder.updates

        let runUpdates = Self.updates(of: Self.completionToken, in: updates)
        #expect(runUpdates.map(\.kind) == [.toolCallUpdate, .terminalUpdate, .terminalOutputChunk])
        #expect(try Self.reassembledBytes(in: runUpdates) == Self.thirdChunk)
        #expect(try Self.clientView(in: updates) == stored + Self.thirdChunk)
    }

    /// The updates that belong to one run: its announce, its chunks and its
    /// terminal updates, in send order.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - updates: The sent updates.
    /// - Returns: The updates of the run.
    private static func updates(of token: String, in updates: [SessionUpdate]) -> [SessionUpdate] {
        updates.filter { update in
            switch update {
            case .toolCallUpdate(let call):
                return terminalIds(in: call.content) == [token]
            case .terminalOutputChunk(let chunk):
                return chunk.terminalId.rawValue == token
            case .terminalUpdate(let terminal):
                return terminal.terminalId.rawValue == token
            default:
                return false
            }
        }
    }

    // MARK: - The catalog wiring

    /// Builds the catalog registry over `workingDirectory` with the
    /// shell section enabled and the store redirected to a throwaway
    /// directory.
    ///
    /// The `codeContext:` section is off. This suite does not test the
    /// code context, and each build with the section on starts a
    /// `CodeContext` that runs until the test process ends.
    ///
    /// - Parameter workingDirectory: The session working directory.
    /// - Returns: The built registry.
    /// - Throws: Whatever the catalog build throws.
    private static func makeBuiltRegistry(
        workingDirectory: URL
    ) async throws -> ToolCatalog.BuiltRegistry {
        var configuration = AgentConfiguration()
        configuration.tools.codeContext = .disabled
        configuration.tools.shell = .enabled(
            ShellToolOptions(storeDirectory: makeResolvedDirectory(named: "store")))
        return try await CatalogRegistryFixture.makeBuiltRegistry(
            workingDirectory: workingDirectory, configuration: configuration)
    }

    /// The catalog builds the host-owned stream exactly when the shell
    /// section is enabled.
    @Test func theCatalogBuildsTheStreamOnlyWhenShellIsEnabled() async throws {
        let enabled = try await Self.makeBuiltRegistry(
            workingDirectory: Self.makeResolvedDirectory(named: "enabled"))
        #expect(enabled.shellOutput != nil)

        var configuration = AgentConfiguration()
        configuration.tools.codeContext = .disabled
        configuration.tools.shell = .disabled
        let disabled = try await CatalogRegistryFixture.makeBuiltRegistry(
            workingDirectory: Self.makeResolvedDirectory(named: "disabled"),
            configuration: configuration)
        #expect(disabled.shellOutput == nil)
    }

    // MARK: - The end-to-end run

    /// Waits until the recorder holds a terminal update that claims the
    /// exit.
    ///
    /// - Parameter recorder: The recorder to poll.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitForExit(on recorder: SinkRecorder) async throws {
        for _ in 0..<ScriptedPromptFixture.maxPollAttempts {
            let updates = await recorder.updates
            let exited = terminalUpdates(in: updates).contains { terminal in
                if case .value = terminal.exitStatus { return true }
                return false
            }
            if exited { return }
            try await Task.sleep(for: ScriptedPromptFixture.pollInterval)
        }
        Issue.record("the exit update never arrived")
    }

    /// A real command's bytes reassemble exactly from the client-end
    /// chunk stream: the fixture writes invalid UTF-8 between plain
    /// words, the chunks decode back to those bytes, the reference and
    /// the chunks agree on the id, and `snapshot(for:)` holds the same
    /// bytes as the stored record.
    @Test(.timeLimit(.minutes(1)))
    func aRealCommandsBytesReassembleFromTheClientEndChunkStream() async throws {
        let root = Self.makeResolvedDirectory(named: "run")
        let built = try await Self.makeBuiltRegistry(workingDirectory: root)
        let shellOutput = try #require(built.shellOutput)
        let recorder = SinkRecorder()
        let reader = TerminalStream.start(over: shellOutput) { update in
            await recorder.append(update)
        }

        _ = try await ShellVerbSupport.invokeExecute(
            in: built.registry, command: Self.fixtureCommand, workingDirectory: root)
        try await Self.waitForExit(on: recorder)
        shellOutput.finish()
        await reader.value

        let updates = await recorder.updates
        #expect(try Self.reassembledBytes(in: updates) == Self.fixtureBytes)

        // The reference and every chunk carry the run's one id.
        let call = try #require(toolCallUpdates(in: updates).first)
        let terminalId = try #require(terminalIds(in: call.content).first)
        #expect(terminalChunks(in: updates).allSatisfy { chunk in
            chunk.terminalId.rawValue == terminalId
        })

        // The stored record answers with the same bytes.
        let snapshot = try #require(shellOutput.snapshot(for: terminalId))
        #expect(snapshot.stdout.bytes == Self.fixtureBytes)
    }

    // MARK: - The session teardown

    /// Closing a session finishes the host-owned stream, so a stream
    /// nobody listens to keeps nothing.
    @Test(.timeLimit(.minutes(1)))
    func markingASessionClosedFinishesTheHostOwnedStream() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: [.endPass], label: "TerminalStreamTests-close")
        let stream = try #require(
            await fixture.harness.agent.sessions[fixture.sessionId]?.surface.shellOutput)
        #expect(!stream.isFinished)

        await fixture.harness.agent.markSessionClosed(fixture.sessionId)

        #expect(stream.isFinished)
        await fixture.close()
    }
}

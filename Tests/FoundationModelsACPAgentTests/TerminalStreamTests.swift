import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The terminal display stream (plan.md §11.8): the shell capability's
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

    // MARK: - The terminal reference (§11.8)

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

    // MARK: - The chunk stream (§11.8)

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

    // MARK: - The gap replacement (§11.8)

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
        guard case .value(let output) = terminal.output else {
            Issue.record("expected an output replacement, got \(terminal.output)")
            return
        }
        let data = try #require(Data(base64Encoded: output.data))
        #expect(Array(data) == stdout + stderr)
    }

    // MARK: - The exit status (§11.8)

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
        guard case .value(let output) = terminal.output else {
            Issue.record("expected an output replacement, got \(terminal.output)")
            return
        }
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

    // MARK: - The catalog wiring (§11.8)

    /// Builds the catalog registry over `workingDirectory` with the
    /// shell section enabled and the store redirected to a throwaway
    /// directory.
    ///
    /// - Parameter workingDirectory: The session working directory.
    /// - Returns: The built registry.
    /// - Throws: Whatever the catalog build throws.
    private static func makeBuiltRegistry(
        workingDirectory: URL
    ) async throws -> ToolCatalog.BuiltRegistry {
        var configuration = AgentConfiguration()
        configuration.tools.shell = .enabled(
            ShellToolOptions(storeDirectory: makeResolvedDirectory(named: "store")))
        let context = CatalogContext(
            workingDirectory: workingDirectory,
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(named: "cache")))
        return try await ToolCatalog.makeRegistry(context: context)
    }

    /// The catalog builds the host-owned stream exactly when the shell
    /// section is enabled.
    @Test func theCatalogBuildsTheStreamOnlyWhenShellIsEnabled() async throws {
        let enabled = try await Self.makeBuiltRegistry(
            workingDirectory: Self.makeResolvedDirectory(named: "enabled"))
        #expect(enabled.shellOutput != nil)

        var configuration = AgentConfiguration()
        configuration.tools.shell = .disabled
        let context = CatalogContext(
            workingDirectory: Self.makeResolvedDirectory(named: "disabled"),
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: Self.makeResolvedDirectory(named: "disabled-cache")))
        let disabled = try await ToolCatalog.makeRegistry(context: context)
        #expect(disabled.shellOutput == nil)
    }

    // MARK: - The end-to-end run (§11.8, plan.md §20.1)

    /// Waits until the recorder holds a terminal update that claims the
    /// exit.
    ///
    /// - Parameter recorder: The recorder to poll.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitForExit(on recorder: SinkRecorder) async throws {
        for _ in 0..<ScriptedTurnFixture.maxPollAttempts {
            let updates = await recorder.updates
            let exited = terminalUpdates(in: updates).contains { terminal in
                if case .value = terminal.exitStatus { return true }
                return false
            }
            if exited { return }
            try await Task.sleep(for: ScriptedTurnFixture.pollInterval)
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

    // MARK: - The session teardown (§11.8)

    /// Closing a session finishes the host-owned stream, so a stream
    /// nobody listens to keeps nothing.
    @Test(.timeLimit(.minutes(1)))
    func markingASessionClosedFinishesTheHostOwnedStream() async throws {
        let fixture = try await ScriptedTurnFixture.make(
            script: [.endTurn], label: "TerminalStreamTests-close")
        let stream = try #require(
            await fixture.harness.agent.sessions[fixture.sessionId]?.surface.shellOutput)
        #expect(!stream.isFinished)

        await fixture.harness.agent.markSessionClosed(fixture.sessionId)

        #expect(stream.isFinished)
        await fixture.close()
    }
}

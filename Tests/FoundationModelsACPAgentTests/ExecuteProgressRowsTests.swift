import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// Task ^p8c7snm: a background `execute` run of a command that writes many
/// single bytes gives a bounded count of transcript rows.
///
/// In the bench run of 2026-10-05, one Django test run (django__django-14667)
/// wrote 13663 `toolOutput` rows for one operation: the Django test runner
/// writes one unbuffered "." to stderr for each test, `execute` posted one
/// progress event for each chunk, and the Router journal wrote one row for
/// each event. Two upstream corrections stop the flood:
///
/// - Multitool `^2ny3k6k` collects the output chunks of a run into one
///   progress event for each second, for each 64 KiB, and at the end.
/// - Router `^zze1067` merges consecutive progress events of one run into
///   one journal row. The merged row is written at the next different entry,
///   or at the close of the session. Thus these proofs close the session
///   before they read the transcript.
///
/// The proofs drive the real agent over the scripted model: the agent
/// composes its real tool catalog and a Router session that records. The
/// scripted model calls `runCode`, the snippet calls `tools.shell.execute`,
/// and the command runs in the background under the real sandbox. The prompt
/// waits for the mail of the settled run, so the run has ended when the
/// prompt is idle. No weights load and no network is used.
@Suite struct ExecuteProgressRowsTests {
    // MARK: - Constants

    /// The marker of the prompt that starts the writer.
    private static let startMarker = "Start the one-byte writer"

    /// The text of the answer that the mail of the settled run starts.
    private static let mailReply = "the writer ended"

    /// How many single bytes the command writes, one write for each byte, as
    /// a test runner writes one byte for each test.
    private static let writeCount = 10_000

    /// The most `toolOutput` rows the operation of the writer can have. The
    /// count must not grow with ``writeCount``: before the upstream
    /// corrections, the same command could give one row for each write.
    private static let rowBound = 100

    /// The byte the command writes, one write at a time.
    private static let writtenByte: Character = "."

    /// The start of each progress line that reports output of stderr.
    private static let stderrPrefix = "stderr: "

    /// The shell command: a loop that writes ``writtenByte`` to stderr
    /// ``writeCount`` times, with one write for each byte. The loop uses only
    /// the shell, so it needs no interpreter and no network.
    private static let writerCommand =
        "i=0; while [ $i -lt \(writeCount) ]; do printf '\(writtenByte)' >&2; i=$((i+1)); done"

    /// The snippet of the prompt: one shell run of ``writerCommand``. The
    /// shell gives its pending answer at once, so the run goes on in the
    /// background.
    private static let writerSnippet =
        #"return await tools.shell.execute({ command: "\#(writerCommand)" });"#

    // MARK: - One recorded run

    /// The recorded rows of the writer operation: each `toolOutput` event of
    /// the session that carries an operation event of the writer run.
    private struct WriterRows {
        /// The completion token of the writer run.
        let token: String

        /// The `toolOutput` events of the session that carry an event of the
        /// writer run, in transcript order.
        let rows: [TranscriptEvent]

        /// The operation events of the writer run in ``rows``, in order.
        var events: [OperationEvent] {
            rows.flatMap(\.operationEvents).filter { $0.correlationID == token }
        }

        /// The detail of each progress event of the writer run that reports
        /// output of stderr, in order. The first progress event of a
        /// background run is its pending envelope, and it reports no output.
        var stderrDetails: [String] {
            events.filter(ExecuteProgressRowsTests.reportsStderr).map(\.detail)
        }
    }

    /// Tells if `event` is a progress event that reports output of stderr.
    ///
    /// - Parameter event: The recorded operation event.
    /// - Returns: `true` for a progress event whose detail starts with
    ///   ``stderrPrefix``.
    private static func reportsStderr(_ event: OperationEvent) -> Bool {
        event.kind == .progress && event.detail.hasPrefix(stderrPrefix)
    }

    /// The script of the proofs. The prompt with the marker starts the
    /// writer. The answer that the mail of the settled run starts carries no
    /// marker, so it plays the reply and ends.
    ///
    /// - Returns: The script.
    /// - Throws: When the arguments of the `runCode` call cannot be encoded.
    private static func makeScript() throws -> [ScriptedPassStep] {
        [
            .onPrompt(
                containing: startMarker,
                play: try ScriptedPromptFixture.makeToolPromptScript(code: writerSnippet)),
            .textDelta(mailReply),
            .endPass,
        ]
    }

    /// Drives one prompt that runs the writer, waits until the prompt is
    /// idle, closes the session, and reads the transcript back.
    ///
    /// The close comes before the read: the Router journal writes the merged
    /// progress row of a run at the next different entry, or at the close of
    /// the session.
    ///
    /// - Parameter label: The directory label of the calling proof.
    /// - Returns: The recorded rows of the writer operation.
    /// - Throws: Whatever the wiring, the prompt, the wait or the read throws.
    private static func recordWriterRun(label: String) async throws -> WriterRows {
        let fixture = try await ScriptedPromptFixture.make(script: try makeScript(), label: label)
        let root = try ResumeSessionFixture.projectRecordingRoot(of: fixture.cwd)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: startMarker))
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        let events = try ResumeSessionFixture.recordedEvents(under: root, sessionId: fixture.sessionId)
        let token = try writerToken(in: events)
        let rows = events.filter { event in
            event.kind == .toolOutput && event.operationEvents.contains { $0.correlationID == token }
        }
        return WriterRows(token: token, rows: rows)
    }

    /// The completion token of the writer run: the one run of the session
    /// whose progress reports output of stderr.
    ///
    /// - Parameter events: The recorded events of the session.
    /// - Returns: The token of the writer run.
    /// - Throws: When no run, or more than one run, reports output of stderr.
    private static func writerToken(in events: [TranscriptEvent]) throws -> String {
        let tokens = Set(
            events.flatMap(\.operationEvents).filter(reportsStderr).map(\.correlationID))
        try #require(tokens.count == 1, "expected one run that reports stderr, got \(tokens.sorted())")
        return try #require(tokens.first)
    }

    // MARK: - The proofs

    /// The acceptance of the card: 10000 single-byte writes give fewer than
    /// ``rowBound`` `toolOutput` rows for the operation, and not one row for
    /// each write.
    @Test(.timeLimit(.minutes(1)))
    func manySingleByteWritesGiveABoundedCountOfRows() async throws {
        let writer = try await Self.recordWriterRun(label: "ExecuteProgressRowsTests-rows")

        #expect(writer.events.contains { $0.kind == .completed })
        #expect(
            writer.rows.count < Self.rowBound,
            "the writer operation wrote \(writer.rows.count) toolOutput rows")
    }

    /// The bound loses no output: the progress events in the rows of the
    /// operation hold each byte the command wrote.
    @Test(.timeLimit(.minutes(1)))
    func theBoundedRowsKeepEachWrittenByte() async throws {
        let writer = try await Self.recordWriterRun(label: "ExecuteProgressRowsTests-text")

        let keptByteCount = writer.stderrDetails.joined().count { $0 == Self.writtenByte }
        #expect(keptByteCount == Self.writeCount)
    }
}

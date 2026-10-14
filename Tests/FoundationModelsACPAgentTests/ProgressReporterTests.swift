import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import acp_agent

/// The model resolution drawn on stderr while it runs (cli-plan.md §5.7).
///
/// The reporter takes its renderer as an argument, and the renderer takes
/// its destination and its terminal test as arguments, so both rows of the
/// §5.7 table run with a pipe and a plain boolean. No test needs a
/// pseudo-terminal, and no test downloads a model.
///
/// The progress object is an argument as well. Router keeps
/// `SlotProgress.init` internal, so no test outside Router can put byte
/// counts into a real `ResolutionProgress`. The reporter reads through
/// ``ResolutionProgressReading``, and ``ScriptedResolutionProgress`` is the
/// scripted side of that seam.
///
/// The suite is serialized because one test points descriptor 1 at a
/// throwaway file for the length of a run. A parallel suite that wrote to
/// stdout in that window would land in the same file.
@Suite(.serialized) struct ProgressReporterTests {
    // MARK: - Constants

    /// The line of the first scripted read: the models are being sized, and
    /// no slot downloads yet.
    private static let sizingLabel = "sizing"

    /// The line of the second scripted read: one slot downloads, and the
    /// line names it.
    private static let downloadingLabel = "downloading standard"

    /// The line of the last scripted read: the resolution ended.
    private static let readyLabel = "ready"

    /// The completed half of the byte pair the middle read carries: one
    /// mebibyte.
    private static let completedBytes: Int64 = 1_048_576

    /// The total half of the byte pair the middle read carries: two
    /// mebibytes.
    private static let totalBytes: Int64 = 2_097_152

    /// What the bar must show for that byte pair.
    private static let byteText = "1.0 MB / 2.0 MB"

    /// The fraction of the middle read, which matches ``completedBytes``
    /// over ``totalBytes``.
    private static let downloadingFraction = 0.5

    /// The fraction of the last read: the whole resolution is complete.
    private static let readyFraction = 1.0

    /// The pause of the reporter between two reads of the progress object.
    /// It is short, because the script advances on each read and nothing
    /// here waits for real work. The test itself waits on no clock.
    private static let pollInterval = Swift.Duration.milliseconds(1)

    /// The line of the one read of ``LateReadProgress``.
    private static let lateLabel = "late read"

    // MARK: - The two rows of the §5.7 table

    /// A run whose destination is a terminal writes the phase, the slot and
    /// the byte counts.
    @Test func aTerminalDestinationGetsThePhaseAndTheByteCounts() async throws {
        let capture = TerminalCapture()
        let progress = await ScriptedResolutionProgress(script: Self.script)
        let reporter = ProgressReporter(
            renderer: TerminalRenderer(destination: capture.destination, isTerminal: true),
            pollInterval: Self.pollInterval)

        try await reporter.report(on: progress) {
            try await Self.waitForTheWholeScript(of: progress)
        }

        let drawn = capture.text()
        #expect(drawn.contains(Self.sizingLabel))
        #expect(drawn.contains(Self.downloadingLabel))
        #expect(drawn.contains(Self.byteText))
    }

    /// A run whose destination is not a terminal writes no byte at all,
    /// which is the second row of the §5.7 table.
    @Test func aDestinationThatIsNotATerminalGetsNoByte() async throws {
        let capture = TerminalCapture()
        let progress = await ScriptedResolutionProgress(script: Self.script)
        let reporter = ProgressReporter(
            renderer: TerminalRenderer(destination: capture.destination, isTerminal: false),
            pollInterval: Self.pollInterval)

        try await reporter.report(on: progress) {
            try await Self.waitForTheWholeScript(of: progress)
        }

        #expect(capture.bytes().isEmpty)
    }

    /// The work runs on both rows, so a run on a pipe still resolves and
    /// still gives its value back.
    @Test func theWorkRunsWhenTheDestinationIsNotATerminal() async throws {
        let capture = TerminalCapture()
        let progress = await ScriptedResolutionProgress(script: Self.script)
        let reporter = ProgressReporter(
            renderer: TerminalRenderer(destination: capture.destination, isTerminal: false),
            pollInterval: Self.pollInterval)

        let resolved = try await reporter.report(on: progress) { "resolved" }

        #expect(resolved == "resolved")
    }

    // MARK: - The reporter never touches descriptor 1

    /// A full progress run on a terminal destination leaves descriptor 1
    /// empty. The answer of a `run` prompt owns stdout (cli-plan.md §5.6),
    /// and the download bar must never reach it.
    @Test func aFullProgressRunLeavesDescriptorOneEmpty() async throws {
        let capture = TerminalCapture()
        let progress = await ScriptedResolutionProgress(script: Self.script)
        let reporter = ProgressReporter(
            renderer: TerminalRenderer(destination: capture.destination, isTerminal: true),
            pollInterval: Self.pollInterval)

        let onStandardOutput = try await Self.capturingStandardOutput {
            try await reporter.report(on: progress) {
                try await Self.waitForTheWholeScript(of: progress)
            }
        }

        #expect(onStandardOutput.isEmpty)
        #expect(!capture.bytes().isEmpty)
    }

    // MARK: - Every read is a main-actor read

    /// Router's `ResolutionProgress` is `@MainActor`, so every read of it is
    /// a main-actor hop. The reporter takes that hop for each read.
    @Test func theReporterReadsTheProgressOnTheMainActor() async throws {
        let capture = TerminalCapture()
        let progress = await ScriptedResolutionProgress(script: Self.script)
        let reporter = ProgressReporter(
            renderer: TerminalRenderer(destination: capture.destination, isTerminal: true),
            pollInterval: Self.pollInterval)

        try await reporter.report(on: progress) {
            try await Self.waitForTheWholeScript(of: progress)
        }

        #expect(await progress.readCount >= Self.script.count)
        #expect(await progress.wasAlwaysReadOnTheMainThread)
    }

    // MARK: - Every draw ends before the report returns

    /// One step of the late-read test, in the order it came.
    enum ReportStep: Equatable, Sendable {
        /// A step that the reporter gave to its observer.
        case reporter(acp_agent.ProgressReporter.Step)

        /// `report(on:)` returned to the test.
        case returned
    }

    /// The last draw of the poll lands before `report(on:)` returns.
    ///
    /// The one read of ``LateReadProgress`` tells the work to return, and
    /// then holds the main thread until a release. The test releases it at
    /// one of two events, whichever comes first: the reporter waits for its
    /// poll (``ProgressReporter/Step/waitingForPoll``), or `report(on:)`
    /// returned. A reporter that waits for its poll thus draws, and then
    /// returns. A reporter that does not wait returns while the read is still
    /// held, and draws only after its return. The test checks the order of
    /// the steps, so such a reporter fails each time, with no clock. Such a
    /// late draw goes at the same time as the completion line of the bar,
    /// and into a destination that the caller can already have closed. A
    /// draw into a pipe with no read end raises `SIGPIPE`, which ends the
    /// whole test process.
    @Test func theLastDrawLandsBeforeTheReportReturns() async throws {
        let capture = TerminalCapture()
        let (readStarts, readStarted) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let steps = WatchedValue<[ReportStep]>([])
        let progress = await LateReadProgress(
            snapshot: ResolutionSnapshot(
                label: Self.lateLabel,
                fraction: Self.readyFraction,
                bytes: TerminalRenderer.ByteProgress(
                    completed: Self.totalBytes, total: Self.totalBytes),
                isFinished: true),
            release: release,
            readStarted: readStarted)
        var reporter = ProgressReporter(
            renderer: TerminalRenderer(destination: capture.destination, isTerminal: true),
            pollInterval: Self.pollInterval)
        reporter.observer = { step in
            steps.update { $0.append(.reporter(step)) }
            if step == .waitingForPoll {
                release.signal()
            }
        }

        try await reporter.report(on: progress) {
            for await _ in readStarts { break }
        }
        steps.update { $0.append(.returned) }
        // A reporter that did not wait for its poll gets its read back only
        // now, after its return.
        release.signal()

        let order = steps.value
        let drawn = try #require(order.firstIndex(of: .reporter(.drew)), "no draw before the return: \(order)")
        let returned = try #require(order.firstIndex(of: .returned))
        #expect(drawn < returned)
        #expect(capture.text().contains(Self.lateLabel))
    }

    // MARK: - Helpers

    /// The scripted resolution: sizing with no bytes, one slot downloading
    /// with a byte pair, and the ready read that ends the run.
    private static var script: [ResolutionSnapshot] {
        [
            ResolutionSnapshot(
                label: sizingLabel,
                fraction: 0,
                bytes: TerminalRenderer.ByteProgress(completed: 0, total: 0),
                isFinished: false),
            ResolutionSnapshot(
                label: downloadingLabel,
                fraction: downloadingFraction,
                bytes: TerminalRenderer.ByteProgress(
                    completed: completedBytes, total: totalBytes),
                isFinished: false),
            ResolutionSnapshot(
                label: readyLabel,
                fraction: readyFraction,
                bytes: TerminalRenderer.ByteProgress(
                    completed: totalBytes, total: totalBytes),
                isFinished: true),
        ]
    }

    /// Waits until `progress` has given every snapshot of its script away,
    /// which is what a real resolution does before it returns. Each read
    /// checks the count again, so the wait uses no clock and no poll.
    ///
    /// - Parameter progress: The scripted progress the reporter reads.
    /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled
    ///   first.
    private static func waitForTheWholeScript(of progress: ScriptedResolutionProgress) async throws {
        let scriptLength = progress.scriptLength
        _ = try await progress.reads.wait(for: "the reporter read the whole script") { $0 >= scriptLength }
    }

    /// Runs `body` with descriptor 1 pointed at a throwaway file, and gives
    /// back the bytes that landed there.
    ///
    /// A file, and not a pipe: a full pipe buffer would block the run, and a
    /// file takes every byte and reads back at any time.
    ///
    /// - Parameter body: The work to run while descriptor 1 is captured.
    /// - Returns: The bytes descriptor 1 received.
    /// - Throws: Whatever `body` throws, or the file error.
    private static func capturingStandardOutput(
        _ body: () async throws -> Void
    ) async throws -> Data {
        let url = makeResolvedDirectory(label: "ProgressReporterTests-stdout")
            .appendingPathComponent("stdout.txt")
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }

        let saved = dup(STDOUT_FILENO)
        defer { close(saved) }
        dup2(file.fileDescriptor, STDOUT_FILENO)

        do {
            try await body()
        } catch {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
            throw error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        return try Data(contentsOf: url)
    }
}

/// A scripted stand-in for Router's `ResolutionProgress`.
///
/// Router keeps `SlotProgress.init` internal, so no test outside Router can
/// put byte counts into a real progress object. This type conforms to the
/// same ``ResolutionProgressReading`` seam the reporter reads, and hands out
/// one scripted snapshot for each read, in script order. The last snapshot
/// repeats, so a read after the end of the script still answers.
///
/// It also records what the reporter did: how many reads arrived, and
/// whether every one of them arrived on the main thread.
@MainActor final class ScriptedResolutionProgress: ResolutionProgressReading {
    /// The snapshots to hand out, in order. It is never empty.
    private let script: [ResolutionSnapshot]

    /// The number of snapshots of the script.
    nonisolated let scriptLength: Int

    /// The count of the reads, with its waits. A test waits on it.
    nonisolated let reads = WatchedValue(0)

    /// How many reads arrived.
    private(set) var readCount = 0

    /// Whether every read so far arrived on the main thread.
    private(set) var wasAlwaysReadOnTheMainThread = true

    /// Creates a scripted progress over one script.
    ///
    /// - Parameter script: The snapshots to hand out, in order. It must
    ///   hold at least one snapshot.
    init(script: [ResolutionSnapshot]) {
        precondition(!script.isEmpty, "a scripted resolution needs at least one snapshot")
        self.script = script
        scriptLength = script.count
    }

    var resolutionSnapshot: ResolutionSnapshot {
        wasAlwaysReadOnTheMainThread = wasAlwaysReadOnTheMainThread && Thread.isMainThread
        let snapshot = script[min(readCount, script.count - 1)]
        readCount += 1
        reads.update { $0 += 1 }
        return snapshot
    }

    /// Whether every snapshot of the script has been handed out.
    var isExhausted: Bool { readCount >= script.count }
}

/// A stand-in for Router's `ResolutionProgress` whose read is slow.
///
/// Each read first tells ``readStarted`` that it began. It then holds the
/// main thread until the test signals ``release``, and only then gives back
/// its snapshot. A test whose work returns on the first signal thus has a
/// read that is still open when the work ends. The work runs off the main
/// actor, so the hold cannot block it.
@MainActor final class LateReadProgress: ResolutionProgressReading {
    /// The snapshot each read gives back.
    private let snapshot: ResolutionSnapshot

    /// The release of the held read. Each read holds the main thread until
    /// it comes.
    private let release: DispatchSemaphore

    /// The signal each read sends when it begins.
    private let readStarted: AsyncStream<Void>.Continuation

    /// Creates a slow progress over one snapshot.
    ///
    /// - Parameters:
    ///   - snapshot: The snapshot each read gives back.
    ///   - release: The release of the held read.
    ///   - readStarted: The signal each read sends when it begins.
    init(
        snapshot: ResolutionSnapshot,
        release: DispatchSemaphore,
        readStarted: AsyncStream<Void>.Continuation
    ) {
        self.snapshot = snapshot
        self.release = release
        self.readStarted = readStarted
    }

    var resolutionSnapshot: ResolutionSnapshot {
        readStarted.yield()
        release.wait()
        return snapshot
    }
}

import ArgumentParser
import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// A ``ModelLoader`` that writes the part file a transfer leaves behind and
/// then stops in the download until its task is cancelled.
///
/// It stands for a real download of a many-gigabyte model: the transfer has
/// started, some bytes are on disk, and the only thing that ends it is the
/// person who presses `Ctrl-C`. `Task.sleep(for:)` is what makes the stop
/// cancellable, so the suite needs no network and no weights.
private struct ParkingDownloadLoader: ModelLoader {
    /// The directory standing in for the Hugging Face cache.
    let cacheDirectory: URL

    /// Yielded once the transfer has written its part file and stopped.
    let parked: AsyncStream<Void>.Continuation

    /// The bytes a part file holds — the share of the transfer that already
    /// reached the disk.
    static let partFileByteCount = 512

    /// The bytes the whole transfer would have moved, had it finished.
    static let totalByteCount = 4096

    /// The number of seconds in ``parkDuration``.
    static let parkSeconds = 600

    /// How long the transfer stops for. Far longer than the suite's own time
    /// limit, so only a cancellation ever ends the stop.
    static let parkDuration = Duration.seconds(parkSeconds)

    /// The name of the part file the interrupted transfer leaves behind.
    static let partFileName = "weights.safetensors.incomplete"

    /// Everything but the stopped transfer is the shared stub loader's work,
    /// so the containers this loader vends are the ones every other suite
    /// runs on.
    private let stub = StubModelLoader()

    /// The part file one interrupted transfer leaves behind.
    ///
    /// - Parameter directory: The cache directory the transfer writes into.
    /// - Returns: The part file's location.
    static func partFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(partFileName)
    }

    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        // The bytes that reach the disk before the transfer stops. Nothing
        // below removes them, which is the claim the suite reads back.
        try Data(repeating: 0, count: Self.partFileByteCount)
            .write(to: Self.partFileURL(in: cacheDirectory))
        reporting(
            DownloadProgress(
                bytesDownloaded: Int64(Self.partFileByteCount),
                bytesTotal: Int64(Self.totalByteCount)))
        parked.yield()
        try await Task.sleep(for: Self.parkDuration)
        return try await stub.loadLLM(
            ref: ref, slot: slot, context: context, reporting: reporting)
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        try await stub.loadEmbedder(ref: ref, slot: slot, reporting: reporting)
    }

    func preload(container: any LoadedModelContainer) async throws {
        try await stub.preload(container: container)
    }
}

/// The interrupt of the composition window (cli-plan.md §5.9): a `Ctrl-C`
/// during a model download stops the resolution, the run exits 4, and the
/// partly downloaded model stays in the Hugging Face cache.
///
/// **No case here arms a real signal**, for the reason ``InterruptTests``
/// gives: `signal(SIGINT, SIG_IGN)` changes the disposition of the whole
/// process, and this process is the test runner. Each case drives the
/// production reaction through a scripted watch instead.
///
/// The download is a real `Router.resolve(profile:reporting:)` over a loader
/// that stops in the transfer, so what these cases cancel is the resolve
/// itself and not a stand-in for it.
struct CompositionInterruptTests {
    /// The prompt of every run here. It is never answered: each case ends in
    /// the composition, before a turn begins.
    private static let promptText = "write a haiku"

    /// The exit code a shell gives to a process that `SIGTERM` ended: 128
    /// and the signal number 15.
    private static let signalEndExitCode: Int32 = 143

    /// Records whether the composition task was cancelled when the
    /// composition failed.
    private final class CancelRecord: Sendable {
        /// `true` once a failed composition saw its task cancelled.
        private let cancelled = Mutex(false)

        /// Records the cancel state of the task of a failed composition.
        ///
        /// - Parameter isCancelled: Whether the task was cancelled.
        func record(_ isCancelled: Bool) {
            cancelled.withLock { $0 = isCancelled }
        }

        /// `true` once a failed composition saw its task cancelled.
        var wasCancelled: Bool {
            cancelled.withLock { $0 }
        }
    }

    /// A composer that resolves a real profile through a loader stopped in
    /// the download, and the cache directory that loader writes into.
    ///
    /// - Parameter label: The directory label, so a leftover directory says
    ///   where it came from.
    /// - Returns: The cache directory, the stream that reports the stop, and
    ///   the composer to run under a watch.
    private static func makeParkedComposer(label: String) -> (
        cacheDirectory: URL,
        parked: AsyncStream<Void>,
        compose: @Sendable () async throws -> AgentComposition.Composed
    ) {
        let cacheDirectory = makeResolvedDirectory(label: "\(label)-hub-cache")
        let (parked, continuation) = AsyncStream<Void>.makeStream()
        let loader = ParkingDownloadLoader(
            cacheDirectory: cacheDirectory, parked: continuation)
        return (
            cacheDirectory,
            parked,
            { try await CLICompositionFixture.make(loader: loader, label: label) }
        )
    }

    /// Returns once the transfer has written its part file and stopped.
    ///
    /// - Parameter parked: The stream the loader reports the stop on.
    private static func awaitParkedDownload(_ parked: AsyncStream<Void>) async {
        for await _ in parked {
            return
        }
    }

    // MARK: - The download (cli-plan.md §5.9)

    /// The first interrupt during the download stops the run, and the run
    /// reports the `cancelled` stop reason that exit 4 belongs to.
    @Test(.timeLimit(.minutes(1)))
    func aFirstInterruptDuringTheDownloadEndsTheRunCancelled() async throws {
        let fixture = ConfigCommandFixture(label: "CompositionInterruptTests-download")
        let capture = try AnswerCapture(label: "CompositionInterruptTests-download-answer")
        let parked = Self.makeParkedComposer(label: "CompositionInterruptTests-download")
        let run = try #require(
            try AcpAgentCommand.parseAsRoot(
                ["run", "--cwd", fixture.workspace.path, Self.promptText])
                as? AcpAgentCommand.Run)

        // The watch is armed only once the transfer has stopped, so the
        // signal lands squarely inside the download.
        let result = try await run.perform(
            environment: fixture.stubEnvironment,
            into: capture.writer,
            interruptedBy: Self.armed(after: parked.parked),
            composedBy: parked.compose)

        #expect(result.stopReason == .cancelled)
        #expect(AgentExitCode(prompt: result) == .cancelled)
    }

    /// The download the interrupt stopped leaves its part file in the cache,
    /// so the next run continues it instead of starting it again.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledDownloadKeepsThePartFileInTheCache() async throws {
        let fixture = ConfigCommandFixture(label: "CompositionInterruptTests-parts")
        let capture = try AnswerCapture(label: "CompositionInterruptTests-parts-answer")
        let parked = Self.makeParkedComposer(label: "CompositionInterruptTests-parts")
        let run = try #require(
            try AcpAgentCommand.parseAsRoot(
                ["run", "--cwd", fixture.workspace.path, Self.promptText])
                as? AcpAgentCommand.Run)

        let result = try await run.perform(
            environment: fixture.stubEnvironment,
            into: capture.writer,
            interruptedBy: Self.armed(after: parked.parked),
            composedBy: parked.compose)

        #expect(result.stopReason == .cancelled)
        let kept = try Data(
            contentsOf: ParkingDownloadLoader.partFileURL(in: parked.cacheDirectory))
        #expect(kept.count == ParkingDownloadLoader.partFileByteCount)
    }

    /// The composition window reports the interrupt as
    /// ``CompositionInterrupted`` and not as the resolution failure the
    /// wrapping would otherwise make of it.
    @Test(.timeLimit(.minutes(1)))
    func anInterruptedCompositionIsNotAResolutionFailure() async throws {
        let parked = Self.makeParkedComposer(label: "CompositionInterruptTests-reason")

        await #expect(throws: CompositionInterrupted.self) {
            try await InterruptibleComposition.run(
                interruptedBy: Self.armed(after: parked.parked), parked.compose)
        }
    }

    // MARK: - SIGTERM during the download

    /// A `SIGTERM` during the download of `acp-agent run` cancels the
    /// composition, and the run throws the exit code of an end by a signal.
    /// The code goes to the failure path of ``AcpAgentCommand/main()``, which
    /// flushes the telemetry before the process exits.
    ///
    /// The loader stops in the transfer for longer than the time limit of
    /// the case, so only the cancel can end it.
    @Test(.timeLimit(.minutes(1)))
    func aTerminationDuringTheDownloadEndsTheRunWithTheSignalEndCode() async throws {
        let fixture = ConfigCommandFixture(label: "CompositionInterruptTests-term-run")
        let capture = try AnswerCapture(label: "CompositionInterruptTests-term-run-answer")
        let parked = Self.makeParkedComposer(label: "CompositionInterruptTests-term-run")
        let run = try #require(
            try AcpAgentCommand.parseAsRoot(
                ["run", "--cwd", fixture.workspace.path, Self.promptText])
                as? AcpAgentCommand.Run)

        let thrown = await #expect(throws: ExitCode.self) {
            _ = try await run.perform(
                environment: fixture.stubEnvironment,
                into: capture.writer,
                interruptedBy: InterruptHandler.unwatched,
                terminatedBy: Self.terminated(after: parked.parked),
                composedBy: parked.compose)
        }

        #expect(thrown?.rawValue == Self.signalEndExitCode)
    }

    /// The composition window that `acp-agent acp` uses: a `SIGTERM` cancels
    /// the composition task, and the window throws the exit code of an end
    /// by a signal, not ``CompositionInterrupted``.
    @Test(.timeLimit(.minutes(1)))
    func aTerminatedCompositionCancelsTheDownloadAndThrowsTheSignalEndCode() async throws {
        let parked = Self.makeParkedComposer(label: "CompositionInterruptTests-term")
        let cancelled = CancelRecord()

        let thrown = await #expect(throws: ExitCode.self) {
            try await InterruptibleComposition.run(
                interruptedBy: InterruptHandler.unwatched,
                terminatedBy: Self.terminated(after: parked.parked)
            ) {
                do {
                    return try await parked.compose()
                } catch {
                    cancelled.record(Task.isCancelled)
                    throw error
                }
            }
        }

        #expect(thrown?.rawValue == Self.signalEndExitCode)
        #expect(cancelled.wasCancelled)
    }

    /// A composition no signal reaches runs to its end and is returned.
    @Test(.timeLimit(.minutes(1)))
    func anUnwatchedCompositionIsReturned() async throws {
        let composed = try await InterruptibleComposition.run(
            interruptedBy: InterruptHandler.unwatched
        ) {
            try await CLICompositionFixture.make(
                loader: StubModelLoader(), label: "CompositionInterruptTests-clean")
        }

        #expect(composed.modelSource == .stub)
    }

    /// A watch whose first arrival is offered only once `parked` reports the
    /// download has stopped.
    ///
    /// The delay is what makes the case deterministic: an arrival offered at
    /// install time could reach a composition that has not started its
    /// transfer yet.
    ///
    /// - Parameter parked: The stream the loader reports the stop on.
    /// - Returns: The installer of that watch.
    private static func armed(after parked: AsyncStream<Void>) -> InterruptHandler.Installer {
        {
            let arrival = ScriptedArrival.after(
                { await Self.awaitParkedDownload(parked) }, giving: InterruptHandler.firstArrival)
            return InterruptWatch(arrivals: arrival.arrivals, disarm: arrival.disarm)
        }
    }

    /// A `SIGTERM` watch whose one arrival is offered only once `parked`
    /// reports the download has stopped, for the reason ``armed(after:)``
    /// gives.
    ///
    /// - Parameter parked: The stream the loader reports the stop on.
    /// - Returns: The installer of that watch.
    private static func terminated(after parked: AsyncStream<Void>) -> TerminationHandler.Installer {
        ScriptedTerminationWatch.armed(after: { await Self.awaitParkedDownload(parked) })
    }
}

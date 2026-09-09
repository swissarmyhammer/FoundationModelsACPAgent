import Foundation
import FoundationModelsRouter

/// One read of a model resolution, taken on the main actor.
///
/// Router's `ResolutionProgress` is `@MainActor @Observable`, so every read
/// of its `phase`, its `fraction` and its `slots` is a main-actor hop. The
/// reporter takes that hop one time for each redraw and carries the answer
/// away as this value, so the drawing itself hops nowhere.
struct ResolutionSnapshot: Sendable {
    /// The text that stands beside the bar: the phase, and the slot when
    /// one slot is downloading.
    let label: String

    /// The share of the whole resolution that is complete, from 0 to 1.
    let fraction: Double

    /// The bytes of the slot ``label`` names, and a pair of zeros when no
    /// slot is downloading.
    let bytes: TerminalRenderer.ByteProgress

    /// Whether the resolution ended, so no later read can change the line.
    let isFinished: Bool
}

extension ResolutionSnapshot {
    // MARK: - The words of the line

    /// The word of the `sizing` phase.
    private static let sizingWord = "sizing"

    /// The word of the `downloading` phase.
    private static let downloadingWord = "downloading"

    /// The word of the `loading` phase.
    private static let loadingWord = "loading"

    /// The word of the `ready` phase.
    private static let readyWord = "ready"

    /// The word of the `failed` phase. The reason itself belongs to the
    /// error the resolution throws, which the CLI reports on its own path.
    private static let failedWord = "failed"

    /// The word of the `cancelled` phase.
    private static let cancelledWord = "cancelled"

    /// What stands between the phase word and the slot word.
    private static let labelSeparator = " "

    /// The byte count of a slot that is not downloading.
    private static let noBytes: Int64 = 0

    // MARK: - Construction

    /// Reads `progress` and holds what the bar draws now.
    ///
    /// - Parameter progress: The progress object the router writes.
    @MainActor init(reading progress: ResolutionProgress) {
        let downloading = Self.downloadingSlot(of: progress)
        let phaseWord = Self.word(of: progress.phase)
        self.init(
            label: downloading.map {
                [phaseWord, $0.key.rawValue].joined(separator: Self.labelSeparator)
            } ?? phaseWord,
            fraction: progress.fraction,
            bytes: TerminalRenderer.ByteProgress(
                completed: downloading?.value.bytesDownloaded ?? Self.noBytes,
                total: downloading?.value.bytesTotal ?? Self.noBytes),
            isFinished: Self.isFinished(progress.phase))
    }

    // MARK: - Helpers

    /// The slot the line names: the slot that is downloading now, taken in
    /// raw-value order.
    ///
    /// The order is fixed so a resolution that downloads two slots at one
    /// time names one of them and holds it, instead of moving between the
    /// two on each read.
    ///
    /// - Parameter progress: The progress object to read.
    /// - Returns: The slot and its progress, or `nil` when no slot is
    ///   downloading.
    @MainActor private static func downloadingSlot(
        of progress: ResolutionProgress
    ) -> (key: ModelSlot, value: SlotProgress)? {
        progress.slots
            .filter { $0.value.state == .downloading }
            .min { $0.key.rawValue < $1.key.rawValue }
    }

    /// The word of one phase.
    ///
    /// - Parameter phase: The phase the resolution is in.
    /// - Returns: The word the line opens with.
    private static func word(of phase: ResolutionProgress.Phase) -> String {
        switch phase {
        case .sizing: sizingWord
        case .downloading: downloadingWord
        case .loading: loadingWord
        case .ready: readyWord
        case .failed: failedWord
        case .cancelled: cancelledWord
        }
    }

    /// Whether one phase ends the resolution.
    ///
    /// - Parameter phase: The phase the resolution is in.
    /// - Returns: `true` when no later read can change the line.
    private static func isFinished(_ phase: ResolutionProgress.Phase) -> Bool {
        switch phase {
        case .ready, .failed, .cancelled: true
        case .sizing, .downloading, .loading: false
        }
    }
}

/// What ``ProgressReporter`` reads while the models resolve.
///
/// The seam exists for one measured reason. Router's `SlotProgress.init` is
/// internal, so no code outside Router can put byte counts into a real
/// `ResolutionProgress`, and a test that drew a scripted download could not
/// be written against the class itself. The reporter reads this one
/// property instead, `ResolutionProgress` carries the production
/// conformance, and a test scripts its own.
///
/// It is `@MainActor` because the class it stands for is: every read is a
/// main-actor hop, and the protocol keeps that in the type system.
@MainActor
protocol ResolutionProgressReading: AnyObject, Sendable {
    /// What the bar draws now.
    var resolutionSnapshot: ResolutionSnapshot { get }
}

extension ResolutionProgress: ResolutionProgressReading {
    var resolutionSnapshot: ResolutionSnapshot { ResolutionSnapshot(reading: self) }
}

/// The model resolution, drawn on stderr while it runs (cli-plan.md §5.7).
///
/// The default profile is large and nothing is on disk on a clean machine,
/// so the first `acp-agent run "hello"` downloads gigabytes. A person who
/// asks for a haiku and gets a silent terminal for ten minutes concludes
/// the tool is broken. The bar is not decoration: it is the difference
/// between working and appearing hung.
///
/// **The bar is a poll, and not a subscription.** Router's
/// `ResolutionProgress.phases` yields one element for each change of the
/// phase, and the byte counts of a slot move many times inside one phase.
/// A bar driven by that stream would stand still for the whole of a
/// gigabyte download, so the reporter reads the progress object on a timer
/// instead.
///
/// **The poll starts before the resolution.** The whole resolution stands
/// inside the construction of the agent, so nothing can drive a bar after
/// that construction returns. The caller makes the progress object first,
/// hands it to the composition, and hands the same object here; the poll
/// task starts before the `await` of the composition and is cancelled
/// after it.
///
/// **The bar is erased before the answer.** The resolution ends before the
/// turn opens the wire, so the drawing is over before the first answer
/// chunk can arrive. Nothing here touches file descriptor 1, so the stdout
/// contract of §5.6 stays byte-exact.
struct ProgressReporter: Sendable {
    // MARK: - Constants

    /// The pause between two reads of the progress object.
    ///
    /// It is short enough that a bar moves while a person watches, and long
    /// enough that the main actor is not asked for the answer more often
    /// than a terminal can draw it.
    static let defaultPollInterval = Swift.Duration.milliseconds(100)

    /// The text beside the bar before the first read arrives.
    static let startMessage = "resolving the models"

    // MARK: - Construction

    /// A reporter that draws nothing: the null device, and no terminal.
    ///
    /// This is the default of a caller that says nothing about the bar, so
    /// no suite draws to the process standard error by accident.
    static let silent = ProgressReporter(
        renderer: TerminalRenderer(destination: .nullDevice, isTerminal: false))

    // MARK: - Stored properties

    /// The surface the bar draws on. It draws nothing when its destination
    /// is not a terminal, which is the second row of the §5.7 table.
    let renderer: TerminalRenderer

    /// The pause between two reads of the progress object.
    var pollInterval = ProgressReporter.defaultPollInterval

    // MARK: - Drawing

    /// Runs `work`, and draws `progress` beside a bar while it runs.
    ///
    /// - Parameters:
    ///   - progress: The progress object the resolution writes. It must
    ///     already be the one the resolution reports into, because the poll
    ///     starts before `work` does.
    ///   - work: The work that resolves the models.
    /// - Returns: What `work` gave back.
    /// - Throws: Whatever `work` throws.
    func report<Value>(
        on progress: some ResolutionProgressReading,
        while work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let interval = pollInterval
        return try await renderer.progressBar(message: Self.startMessage) { report in
            let polling = Task { await Self.poll(progress, every: interval, into: report) }
            defer { polling.cancel() }
            return try await work()
        }
    }

    /// Reads `progress` on the main actor and reports each read, until the
    /// resolution ends or the task is cancelled.
    ///
    /// - Parameters:
    ///   - progress: The progress object to read.
    ///   - interval: The pause between two reads.
    ///   - report: The function that draws one line.
    private static func poll(
        _ progress: some ResolutionProgressReading,
        every interval: Swift.Duration,
        into report: @escaping @Sendable (String, Double, TerminalRenderer.ByteProgress) -> Void
    ) async {
        while !Task.isCancelled {
            let snapshot = await progress.resolutionSnapshot
            report(snapshot.label, snapshot.fraction, snapshot.bytes)
            guard !snapshot.isFinished else { return }
            try? await Task.sleep(for: interval)
        }
    }
}

import Evaluations
import Foundation

// MARK: - The eval vocabulary (plan.md §20.3)
//
// One outcome type serves both sides of a sample, in the pattern of
// Router's `CompactionEvaluationOutcome`: the `expected` value carries
// the ground truth alone, and the produced value carries the same
// ground truth plus the graded verdicts and the run stats. The
// `Evaluation` protocol demands `Sample.ExpectedValue == Subject.Value`,
// and one shared type satisfies that with no bridge.

/// The shared `Metric` identities of the four mechanical evaluators.
///
/// `Metric` is a plain value with no shared identity beyond its name,
/// so every call site constructs an equal one from the same name
/// (Router's `CompactionEvalMetric` records the same reason).
enum PythonCLIEvalMetric {
    /// The metric of the pytest re-run: the venv's pytest exits 0.
    static let pytestGreen = Metric("PytestGreen")

    /// The metric of the CLI re-run: the built CLI, run against the
    /// sample's fixed input, prints the sample's fixed output.
    static let cliRuns = Metric("CLIRuns")

    /// The metric of the file check: every required file is on disk.
    static let filesPresent = Metric("FilesPresent")

    /// The metric of the tool-traffic check: the transcript AND the
    /// wire both show real `runCode` tool traffic for the files and
    /// shell verbs.
    static let toolTraffic = Metric("ToolTraffic")
}

/// One grader's verdict: a pass flag and the mechanical evidence that
/// produced it.
struct PythonCLIGradedVerdict: Codable, Sendable, Equatable {
    /// Whether the grader passed the sample.
    let passed: Bool

    /// The mechanical evidence: an exit code, a diff summary, a missing
    /// file list, or the traffic readings. Never a transcript claim.
    let rationale: String
}

/// The run stats one graded sample carries beside its verdicts
/// (plan.md §20.3: the stats ride along, keyed by the resolved model).
struct PythonCLIRunStats: Codable, Sendable, Equatable {
    /// The resolved standard-slot model, read from the recorded
    /// session's `session.json` sidecar. `nil` when the sidecar was
    /// not written.
    let resolvedModel: String?

    /// How many prompt turns the subject drove: the build prompt plus
    /// every continuation prompt (plan.md §20.3: a multi-turn task).
    let turnCount: Int

    /// How many `tool_call_update` upserts the wire carried.
    let toolCallCount: Int

    /// How many session notifications the recorder collected.
    let notificationCount: Int

    /// The turn's token meter, or `nil` when no `usage_update` arrived.
    let usedTokens: Int?

    /// The resolved context size of the token meter, or `nil`.
    let contextSize: Int?

    /// The wall-clock seconds the turn took, prompt to idle.
    let elapsedSeconds: Double
}

/// The ground truth and the produced result of one sample.
struct PythonCLIOutcome: Codable, Sendable, Equatable {
    /// The stable sample id, unique inside the dataset.
    let sampleID: String

    /// The Python module the CLI runs as: `python -m <moduleName>`.
    let moduleName: String

    /// The fixed input: the CLI arguments of the re-run.
    let arguments: [String]

    /// The fixed output the CLI re-run must print, compared after
    /// trimming trailing whitespace.
    let expectedOutput: String

    /// The workspace-relative files that must be on disk.
    let requiredFiles: [String]

    /// The third-party package the CLI must use, installed into the
    /// project-local venv.
    let dependencyPackage: String

    /// The stop reason the turn ended with, or `nil` on the expected
    /// side and for a turn that never reached idle.
    var stopReason: String?

    /// The pytest re-run verdict, or `nil` on the expected side.
    var pytestGreen: PythonCLIGradedVerdict?

    /// The CLI re-run verdict, or `nil` on the expected side.
    var cliRuns: PythonCLIGradedVerdict?

    /// The file-check verdict, or `nil` on the expected side.
    var filesPresent: PythonCLIGradedVerdict?

    /// The tool-traffic verdict, or `nil` on the expected side.
    var toolTraffic: PythonCLIGradedVerdict?

    /// The run stats, or `nil` on the expected side.
    var stats: PythonCLIRunStats?
}

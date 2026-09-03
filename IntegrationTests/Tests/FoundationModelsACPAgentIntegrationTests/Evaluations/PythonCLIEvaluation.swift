import Evaluations
import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import FoundationModelsRouterTestSupport
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsACPAgent

// MARK: - Tier 4: the end-to-end coding eval (plan.md §20.3)
//
// Run it with:
//
//     swift test --package-path IntegrationTests --filter PythonCLIEvaluation
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target. The suite needs Apple silicon,
// the real configured models, and the network — the first run downloads
// the coding profile, and every sample's pip install fetches packages.
//
// The drive takes the whole dataset. ``PythonCLIEvaluation`` takes a
// `sampleLimit`, so a shorter drive is a shorter dataset in code, never
// an environment variable.

/// The ceiling of ONE prompt turn, in seconds: the prompt to its
/// idle terminator, covering a multi-step build with a venv creation
/// and a network package install on a local model. The measured
/// 2026-09-02 probe build on the default 14B model took about one
/// minute end to end.
private let evalSampleIdleCeilingSeconds = 300

/// The number of seconds in one minute, for the suite-ceiling
/// arithmetic.
private let evalSecondsPerMinute = 60

/// The gated suite's wall-clock ceiling in minutes: the whole dataset
/// at the per-turn ceiling times the turn cap, plus one first-run
/// model download and load. A capped evidence run finishes far
/// inside it.
private let evalSuiteTimeLimitMinutes =
    PythonCLIDataset.sampleSpecs.count * evalMaxTurnsPerSample
    * evalSampleIdleCeilingSeconds / evalSecondsPerMinute
    + evalModelLoadAllowanceMinutes

/// The minutes the suite ceiling grants the first-run model download
/// and the resident load, apart from any sample.
private let evalModelLoadAllowanceMinutes = 30

/// The most prompt turns the gated drive sends per sample: the build
/// prompt, then continuation prompts after every stop that is not
/// `end_turn` — a malformed tool call ends a turn with `_error` on
/// the small local models, and the continuation gives the model its
/// next chance over the same transcript.
private let evalMaxTurnsPerSample = 4

/// The standard-slot model the gated tier pins, in Router's own
/// eval convention (`CompactionEvalRealModel`): a NAMED model, so a
/// run's means are attributable and comparable across days. Neither
/// this model nor the in-code default (Qwen2.5-14B-Instruct) cleared
/// the bar on the 2026-09-02 evidence runs; the per-sample evidence
/// lines name the two measured failure modes — malformed tool calls
/// that end a turn with `_error`, and intermittent zero-token empty
/// responses. The pin is for attribution, not a clearing claim.
private let evalStandardModel = "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit"

/// The profile section the gated tier appends to the subject's user
/// config, pinning ``evalStandardModel`` for the standard slot. The
/// flash and embedding slots keep the in-code defaults.
private let evalProfileYAML = """

    profile:
      standard: ["\(evalStandardModel)"]
    """

/// The mean pass-rate floor every metric is asserted against.
///
/// A TARGET bar, not a measured baseline. The 2026-09-02 evidence
/// runs measured 0 of 1 on the evidence sample for both the default
/// and the pinned model, so the gated tier currently fails this bar
/// and its per-sample evidence lines say why. The bar states that at
/// least half the driven samples must pass each metric; re-base it to
/// a measured floor once the models clear samples.
let pythonCLIEvalMeanFloor = 0.5

// MARK: - The evaluation

/// What the evaluation refused.
enum PythonCLIEvaluationError: Error, Equatable {
    /// A sample carried no `expected` value — unreachable in practice,
    /// because ``PythonCLIDataset/makeLoader(limit:)`` always supplies
    /// one.
    case missingExpectedValue
}

/// The end-to-end coding evaluation (plan.md §20.3): each sample asks
/// the composed agent, over ACP, to build a small Python CLI in a
/// fresh sandboxed workspace, and the four mechanical evaluators grade
/// the result from the filesystem, the exit codes, the recorded
/// transcript, and the wire.
///
/// The subject work is injected through ``runSubject``, in the pattern
/// of Router's `CompactionEvaluation`: the gated `@Test` wires the
/// live-model runner, and the ungated unit tests wire fakes, so the
/// dataset and the evaluator plumbing are provable with no model.
struct PythonCLIEvaluation: Evaluation {
    /// The sample type: Apple's `ModelSample` over the shared outcome.
    typealias Sample = ModelSample<PythonCLIOutcome>

    /// The subject type: Apple's `ModelSubject` over the same outcome,
    /// so `Sample.ExpectedValue == Subject.Value` as the protocol
    /// demands.
    typealias Subject = ModelSubject<PythonCLIOutcome>

    /// The dataset cap, or `nil` for every sample.
    let sampleLimit: Int?

    /// Runs one sample's subject work: drives the agent over ACP in a
    /// fresh workspace and returns the graded outcome.
    let runSubject: @Sendable (PythonCLIOutcome) async throws -> PythonCLIOutcome

    /// The hand-written dataset, capped at ``sampleLimit``.
    var dataset: ArrayLoader<Sample> {
        PythonCLIDataset.makeLoader(limit: sampleLimit)
    }

    /// Runs ``runSubject`` for one sample.
    ///
    /// - Parameter sample: The sample to drive.
    /// - Returns: The subject carrying the graded outcome.
    /// - Throws: ``PythonCLIEvaluationError/missingExpectedValue``, or
    ///   whatever the subject work throws.
    func subject(from sample: Sample) async throws -> Subject {
        guard let expected = sample.expected else {
            throw PythonCLIEvaluationError.missingExpectedValue
        }
        return ModelSubject(value: try await runSubject(expected))
    }

    /// The four mechanical evaluators, one per metric. Each reads the
    /// verdict the graders recorded on the produced outcome; a subject
    /// that recorded no verdict fails the metric.
    var evaluators: Evaluators {
        Self.makeVerdictEvaluator(metric: PythonCLIEvalMetric.pytestGreen, verdict: \.pytestGreen)
        Self.makeVerdictEvaluator(metric: PythonCLIEvalMetric.cliRuns, verdict: \.cliRuns)
        Self.makeVerdictEvaluator(metric: PythonCLIEvalMetric.filesPresent, verdict: \.filesPresent)
        Self.makeVerdictEvaluator(metric: PythonCLIEvalMetric.toolTraffic, verdict: \.toolTraffic)
    }

    /// Registers the four metrics for mean aggregation.
    ///
    /// - Parameter aggregator: The aggregator to register with.
    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        for metric in Self.allMetrics {
            aggregator.computeMean(of: metric)
        }
    }

    /// Every metric this evaluation aggregates, in report order.
    static let allMetrics = [
        PythonCLIEvalMetric.pytestGreen,
        PythonCLIEvalMetric.cliRuns,
        PythonCLIEvalMetric.filesPresent,
        PythonCLIEvalMetric.toolTraffic,
    ]

    /// One evaluator that maps a recorded grader verdict onto `metric`.
    ///
    /// - Parameters:
    ///   - metric: The metric the evaluator reports.
    ///   - verdict: Reads the grader's verdict off the produced
    ///     outcome.
    /// - Returns: The evaluator.
    private static func makeVerdictEvaluator(
        metric: Metric,
        verdict: @escaping @Sendable (PythonCLIOutcome) -> PythonCLIGradedVerdict?
    ) -> Evaluator<Sample> {
        Evaluator<Sample> { _, subject in
            guard let graded = verdict(subject.value) else {
                return metric.failing(rationale: "the subject recorded no verdict")
            }
            return graded.passed
                ? metric.passing(rationale: graded.rationale)
                : metric.failing(rationale: graded.rationale)
        }
    }
}

// MARK: - The gated live runner

/// Drives the gated samples one at a time through ONE shared subject
/// host, so the resident model loads once for the whole run. An actor,
/// so the framework's dispatch shape can never overlap two samples on
/// one agent.
private actor PythonCLIGatedRunner {
    /// The shared host, made on the first sample.
    private var host: PythonCLISubjectHost?

    /// Drives one sample end to end and grades it.
    ///
    /// - Parameter expected: The sample's ground truth.
    /// - Returns: The graded outcome.
    /// - Throws: Whatever the host construction or the drive throws.
    func run(expected: PythonCLIOutcome) async throws -> PythonCLIOutcome {
        let host = try await ensureHost()
        guard let spec = PythonCLIDataset.spec(of: expected.sampleID) else {
            throw PythonCLIEvaluationError.missingExpectedValue
        }
        let workspace = makeResolvedDirectory(label: "PythonCLIEval-\(spec.id)")
        let run = try await host.runSample(
            prompt: PythonCLIDataset.prompt(of: spec, workspace: workspace),
            workspace: workspace,
            idleDeadline: .seconds(evalSampleIdleCeilingSeconds),
            maxTurns: evalMaxTurnsPerSample)
        let produced = await PythonCLISubjectHost.gradedOutcome(of: run, expected: expected)
        print(Self.evidenceLine(of: produced))
        return produced
    }

    /// One compact evidence line per graded sample, printed so a run's
    /// log carries the verdicts and the stats beside the aggregate
    /// means (Router's eval progress log records the same need).
    ///
    /// - Parameter produced: The graded outcome.
    /// - Returns: The line.
    private static func evidenceLine(of produced: PythonCLIOutcome) -> String {
        let verdicts = [
            ("pytest", produced.pytestGreen),
            ("cli", produced.cliRuns),
            ("files", produced.filesPresent),
            ("traffic", produced.toolTraffic),
        ]
        .map { name, verdict -> String in
            guard let verdict else { return "\(name)=missing" }
            return verdict.passed
                ? "\(name)=PASS"
                : "\(name)=FAIL(\(verdict.rationale))"
        }
        .joined(separator: " ")
        let stats = produced.stats
        return "PythonCLIEvaluation sample \(produced.sampleID):"
            + " stop=\(produced.stopReason ?? "none")"
            + " turns=\(stats?.turnCount ?? 0)"
            + " toolCalls=\(stats?.toolCallCount ?? 0)"
            + " tokens=\(stats?.usedTokens ?? 0)/\(stats?.contextSize ?? 0)"
            + " elapsed=\(Int(stats?.elapsedSeconds ?? 0))s"
            + " model=\(stats?.resolvedModel ?? "unresolved")"
            + " \(verdicts)"
    }

    /// The shared host, constructing it on the first call: a real
    /// router over `LiveModelLoader` (the `Examples/acp-agent`
    /// recipe), the composed agent with the pinned eval profile —
    /// see ``evalStandardModel`` — and the recording harness wired
    /// over the in-memory pair.
    private func ensureHost() async throws -> PythonCLISubjectHost {
        if let host {
            return host
        }
        // Under `swift test`, mlx-swift does not find its shader
        // library beside the test binary; Router's bootstrap symlinks
        // it once per process, and it must run before the first GPU
        // evaluation (the model load below).
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        let userDirectory = try PythonCLISubjectHost.prepareUserDirectory(
            label: "PythonCLIEval-user")
        try (PythonCLISubjectHost.userConfigYAML + evalProfileYAML).write(
            to: userDirectory.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        // The agent's construction-time profile resolution reads the
        // configuration it is handed, so the pinned profile loads
        // through the same layered stack a session uses.
        let configuration = try ConfigurationLoader(
            name: DotfolderName(AgentClientHarness.dotfolderName),
            workingDirectory: userDirectory,
            userDirectory: userDirectory,
            environment: [:]
        ).load().configuration
        // `recordingsDir` switches the Router recorder on; each
        // session's own recording root then comes from the `home`
        // transcripts location under `userDirectory`.
        let router = Router(
            recordingsDir: makeResolvedDirectory(label: "PythonCLIEval-recordings"),
            loader: LiveModelLoader(
                downloader: #hubDownloader(),
                tokenizerLoader: #huggingFaceTokenizerLoader()))
        let agent = try await RoutedACPAgent(
            name: DotfolderName(AgentClientHarness.dotfolderName),
            router: router,
            configuration: configuration,
            userDirectory: userDirectory,
            environment: [:])
        let made = try await PythonCLISubjectHost.make(agent: agent, userDirectory: userDirectory)
        host = made
        return made
    }
}

/// The one gated runner instance, shared by the file-scope evaluation
/// value the `.evaluates(...)` trait references.
private let pythonCLIGatedRunner = PythonCLIGatedRunner()

/// The live evaluation: the live runner over the whole dataset.
/// Constructing this value is cheap; the model loads inside the first
/// sample's subject work, well after registration.
private let pythonCLIGatedEvaluation = PythonCLIEvaluation(sampleLimit: nil) {
    expected in
    try await pythonCLIGatedRunner.run(expected: expected)
}

// MARK: - The live suite

/// The tier-4 run: the composed agent, the real configured models, real
/// `files` and `shell` in a seatbelt sandbox, driven over ACP for every
/// sample, and graded mechanically.
@Suite(
    .serialized,
    .timeLimit(.minutes(evalSuiteTimeLimitMinutes)))
struct PythonCLIEvaluationTests {
    /// Runs the evaluation over the dataset and asserts every metric's
    /// mean pass rate against ``pythonCLIEvalMeanFloor``. The
    /// per-sample stats — the resolved model, the tool-call and
    /// notification counts, the token meter, and the wall clock — ride
    /// on each produced outcome's `stats`.
    @Test(
        "The composed agent builds Python CLIs end to end over ACP",
        .evaluates(pythonCLIGatedEvaluation, info: ["dataset": "python-cli"]))
    func evaluatePythonCLI() {
        let result = EvaluationContext.current.result
        for metric in PythonCLIEvaluation.allMetrics {
            let mean = result.aggregateValue(.mean(of: metric))
            #expect(
                mean >= pythonCLIEvalMeanFloor,
                "\(metric.name) mean \(mean) is under the floor \(pythonCLIEvalMeanFloor)")
        }
    }
}

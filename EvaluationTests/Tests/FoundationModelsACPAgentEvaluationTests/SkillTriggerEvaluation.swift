import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import FoundationModelsRouterTestSupport
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

// MARK: - The gate

/// The environment variable that sets how many times each sample runs.
///
/// A model is not deterministic, so one run of a sample says little. The
/// Agent Skills standard recommends three runs for each prompt, and a rate
/// over the runs. The default here is the same three.
let skillTriggerRepeatsVariable = "ACP_AGENT_SKILL_TRIGGER_REPEATS"

/// The environment variable that keeps one sample of the dataset, by name.
///
/// A whole run costs minutes, thus a person debugging one sample drives that
/// sample alone: `ACP_AGENT_SKILL_TRIGGER_SAMPLES=who-calls`. A list is
/// comma-separated. With no value, the run drives every sample.
let skillTriggerSamplesVariable = "ACP_AGENT_SKILL_TRIGGER_SAMPLES"

/// The samples of this run, in report order.
var skillTriggerSamples: [SkillTriggerSample] {
    guard let text = ProcessInfo.processInfo.environment[skillTriggerSamplesVariable],
        !text.isEmpty
    else { return SkillTriggerDataset.samples }
    let names = Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    return SkillTriggerDataset.samples.filter { names.contains($0.name) }
}

/// The default number of runs of each sample.
let skillTriggerDefaultRepeats = 3

/// How many times each sample runs.
var skillTriggerRepeats: Int {
    guard let text = ProcessInfo.processInfo.environment[skillTriggerRepeatsVariable],
        let count = Int(text), count > 0
    else { return skillTriggerDefaultRepeats }
    return count
}

// MARK: - The bars

/// The share of the runs of the covered tasks, over the whole dataset, in
/// which the model must load the skill that fits.
///
/// The bar is over the dataset, and not over one sample: a model is not
/// deterministic, and one prompt that a model reads differently must not
/// make the suite red. A rate under the bar says that the catalog, the
/// descriptions or the rules stopped working.
///
/// The Agent Skills standard calls a rate over 0.5 a pass, and this bar is
/// that rule. Three measured runs stand behind it:
///
/// - 2026-09-19, `mlx-community/Qwen3.8-27B-mxfp4`, the shipped standard
///   model, one run of each sample, five covered tasks: every one loaded its
///   skill. Rate 1.0. That run took 28 minutes, because it waited for each
///   whole turn.
/// - 2026-09-20, `mlx-community/Qwen3-4B-4bit`, the small model this suite
///   pins, one run of each sample, three covered tasks: two loaded their
///   skill, and `who-calls` loaded none. Rate 0.67, in 4 minutes.
/// - 2026-09-20, the same small model, three runs of each of the five
///   samples of today: `understand-parser` 1.0, `who-calls` 0.33,
///   `release-notes` 1.0, `swebench-issue` 0.0. Rate 0.58, in 10 minutes.
///
/// **The third run is the one to read.** `swebench-issue` loaded no skill in
/// any of its three runs, and it called `searchTools` alone. That sample is
/// a bug report, thus it holds none of the words of the description of the
/// skill, and it is the condition of the SWE-bench run of 2026-09-19 in one
/// turn of a minute. The rate is still over the bar, because the other four
/// samples work, and that is the split the bar is for: this measures the
/// words of the descriptions and of the rules, and a red suite must mean
/// that the delivery itself broke.
///
/// - 2026-09-21, the same model and samples, with the use rule of Skills
///   `cbbcd37` ("If a skill helps with any part of your task, load it now
///   … Load each skill that helps"): `understand-parser` 1.0, `who-calls`
///   0.67, `release-notes` 1.0, `swebench-issue` 0.33. Rate 0.75, in 11
///   minutes. The same rule made `run-the-tests` load `fixture-explore` in
///   two of three runs, thus the false-load rate was 0.67 and the ceiling
///   below failed. A rule that pushes harder moves both rates.
///
/// **One sample has three runs, thus its rate moves in steps of 0.33.**
/// `who-calls` gave 1.0, 0.33 and 0.67 in three runs with no change of
/// text. Read a change of one sample by one step as noise.
let skillTriggerFloor = 0.5

/// The share of the runs of a task that no skill covers, in which the model
/// may still load a skill.
///
/// A skill that fires on every task is as wrong as one that never fires, so
/// the near-miss samples have a ceiling of their own.
///
/// In the run of 2026-09-19 both near misses stayed clean: "run the test
/// suite" made five `skills` calls and loaded nothing, and the typo task
/// made none.
let skillTriggerFalseCeiling = 0.5

// MARK: - The host

/// The one composed agent of a live run: the real models load one time, and
/// every sample runs its own session against them.
actor SkillTriggerHost {
    /// The made subject, or `nil` before the first sample.
    private var subject: SkillTriggerSubject?

    /// The subject of this run, made at the first call.
    ///
    /// - Returns: The shared subject.
    /// - Throws: Whatever the configuration load, the router, the agent or
    ///   the handshake throws.
    func makeSubject() async throws -> SkillTriggerSubject {
        if let subject {
            return subject
        }
        // Under `swift test`, mlx-swift does not find its shader library
        // beside the test binary. Router's bootstrap symlinks it once per
        // process, and it must run before the first model load.
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        let userDirectory = makeResolvedDirectory(label: "SkillTriggerEval-user")
        try SkillTriggerSubject.userConfigYAML.write(
            to: userDirectory.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        let configuration = try ConfigurationLoader(
            name: DotfolderName(AgentClientHarness.dotfolderName),
            workingDirectory: userDirectory,
            userDirectory: userDirectory,
            environment: [:]
        ).load().configuration
        let router = Router(
            recordingsDir: makeResolvedDirectory(label: "SkillTriggerEval-recordings"),
            loader: LiveModelLoader(
                downloader: #hubDownloader(),
                tokenizerLoader: #huggingFaceTokenizerLoader()))
        let agent = try await RoutedACPAgent(
            name: DotfolderName(AgentClientHarness.dotfolderName),
            router: router,
            configuration: configuration,
            userDirectory: userDirectory,
            environment: [:])
        let harness = await AgentClientHarness.makeRecording(agent: agent)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        guard let collector = harness.collector else {
            preconditionFailure("makeRecording always wires a collector")
        }
        let made = SkillTriggerSubject(
            harness: harness, collector: collector, userDirectory: userDirectory)
        subject = made
        return made
    }
}

/// The host of the gated suite.
let skillTriggerHost = SkillTriggerHost()

// MARK: - The report

/// The rate of one sample over its runs.
struct SkillTriggerRate: Sendable {
    /// The sample.
    let sample: SkillTriggerSample

    /// The runs of that sample.
    let runs: [SkillTriggerRun]

    /// The share of runs that did what the sample asks.
    var rate: Double {
        guard !runs.isEmpty else { return 0 }
        return Double(runs.filter(\.passed).count) / Double(runs.count)
    }

    /// One line for the report.
    var line: String {
        let ids = Set(runs.flatMap(\.loadedSkillIDs)).sorted().joined(separator: ",")
        let expected = sample.expectedSkillID ?? "(none)"
        return
            "\(sample.name) expected=\(expected) rate=\(rate) loaded=[\(ids)] "
            + "skillsCalls=\(runs.map(\.skillsCallCount)) "
            + "toolsSeen=\(Set(runs.flatMap(\.toolTitlesSeen)).sorted()) "
            + "seconds=\(runs.map { Int($0.elapsedSeconds) })"
    }
}

// MARK: - The live suite

/// The live measurement of the question three SWE-bench runs could not
/// answer: does a real model load the skill that fits the task?
///
/// Each sample is a task in the words of a user. It names no skill and no
/// tool. The agent mounts the skills library of the root package, so the
/// model sees the catalog in the description of the `skills` tool and the
/// rules in the instructions. What the model does with that is the result.
///
/// **The gate is the package.** This level needs Apple silicon, the real
/// models and the graphics processor, so no workflow of every commit runs
/// it; `evaluation.yml` drives it when a person asks, and every night at
/// 09:00 UTC with the filter `SkillTrigger`. It is the one suite of this
/// level that a schedule drives, because it takes about ten minutes and the
/// others take hours. The suite carries no gate of its own, as
/// `PythonCLIEvaluationTests` carries none: a run of this package runs it.
///
/// Run it with:
///
/// ```sh
/// swift test --package-path EvaluationTests --filter SkillTriggerEvaluationTests
/// ```
///
/// or `gh workflow run evaluation.yml --field filter=SkillTrigger`.
///
/// `ACP_AGENT_SKILL_TRIGGER_REPEATS` sets the runs of each sample; the
/// default is three. The suite prints one line for each sample, so a run
/// states the rates even when it fails the bars.
@Suite(
    .serialized,
    .timeLimit(.minutes(60)))
struct SkillTriggerEvaluationTests {
    /// Runs every sample, prints the rates, and asserts the two bars.
    @Test("A live model loads the skill that fits the task")
    func aLiveModelLoadsTheSkillThatFitsTheTask() async throws {
        let subject = try await skillTriggerHost.makeSubject()
        var rates: [SkillTriggerRate] = []
        for sample in skillTriggerSamples {
            var runs: [SkillTriggerRun] = []
            for _ in 0..<skillTriggerRepeats {
                runs.append(try await subject.run(sample: sample))
            }
            let rate = SkillTriggerRate(sample: sample, runs: runs)
            // The rates are the result of this suite, thus they go to the
            // reader whether the bars pass or fail.
            print("SKILL TRIGGER \(rate.line)")
            rates.append(rate)
        }

        let covered = rates.filter { $0.sample.expectedSkillID != nil }
        let uncovered = rates.filter { $0.sample.expectedSkillID == nil }
        let loadRate = Self.mean(of: covered.map(\.rate))
        let falseLoadRate = 1 - Self.mean(of: uncovered.map(\.rate))
        print("SKILL TRIGGER TOTAL loadRate=\(loadRate) falseLoadRate=\(falseLoadRate)")

        let floorMessage: Comment = """
            the model loaded the fitting skill in \(loadRate) of the runs of the covered \
            tasks, under the floor \(skillTriggerFloor)
            """
        #expect(loadRate >= skillTriggerFloor, floorMessage)
        let ceilingMessage: Comment = """
            the model loaded a skill in \(falseLoadRate) of the runs of the tasks that no \
            skill covers, over the ceiling \(skillTriggerFalseCeiling)
            """
        #expect(falseLoadRate <= skillTriggerFalseCeiling, ceilingMessage)
    }

    /// The mean of `values`, or zero for an empty list.
    ///
    /// - Parameter values: The rates to average.
    /// - Returns: The mean.
    private static func mean(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

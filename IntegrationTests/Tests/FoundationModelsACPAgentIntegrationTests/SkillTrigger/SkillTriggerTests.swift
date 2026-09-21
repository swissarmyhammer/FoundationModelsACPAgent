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

// MARK: - The selection

/// The environment variable that sets how many times each sample runs.
///
/// The default is one run, because the decoding is greedy: a second run of
/// the same sample gives the same decision, and only costs time. A person
/// who measures a sampling model sets three, as the Agent Skills standard
/// recommends.
let skillTriggerRepeatsVariable = "ACP_AGENT_SKILL_TRIGGER_REPEATS"

/// The environment variable that names the samples of a run.
///
/// With no value, the run drives the gate (``SkillTriggerDataset/gate``),
/// which is what CI runs. A comma-separated list of names drives those
/// samples instead: `ACP_AGENT_SKILL_TRIGGER_SAMPLES=who-calls,swebench-issue`.
let skillTriggerSamplesVariable = "ACP_AGENT_SKILL_TRIGGER_SAMPLES"

/// The samples of this run, in report order.
var skillTriggerSamples: [SkillTriggerSample] {
    guard let text = ProcessInfo.processInfo.environment[skillTriggerSamplesVariable],
        !text.isEmpty
    else { return SkillTriggerDataset.gate }
    let names = Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    return SkillTriggerDataset.samples.filter { names.contains($0.name) }
}

/// The default number of runs of each sample.
let skillTriggerDefaultRepeats = 1

/// How many times each sample runs.
var skillTriggerRepeats: Int {
    guard let text = ProcessInfo.processInfo.environment[skillTriggerRepeatsVariable],
        let count = Int(text), count > 0
    else { return skillTriggerDefaultRepeats }
    return count
}

// MARK: - The bar

/// The share of the runs of each sample in which the model must load the
/// skill that fits.
///
/// The bar is for each sample, and not for the mean of the samples: a gate
/// sample that stops loading its skill is the defect, and a mean hides it.
/// With one run, a sample passes when the model loads its skill. With three
/// runs, the Agent Skills standard calls a rate over 0.5 a pass, and this
/// bar is that rule.
///
/// The measured history of the rates stands in `bench/README.md`, under
/// "The fast answer to the same question".
let skillTriggerFloor = 0.5

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
        let userDirectory = makeResolvedDirectory(label: "SkillTrigger-user")
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
            recordingsDir: makeResolvedDirectory(label: "SkillTrigger-recordings"),
            loader: LiveModelLoader(
                downloader: #hubDownloader(),
                tokenizerLoader: #huggingFaceTokenizerLoader()),
            // Greedy decoding makes a run repeatable (read the suite).
            samplingMode: .greedy)
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
            + runs.filter { !$0.passed }.map { run in
                " stop=\(run.stopReason.map { "\($0)" } ?? "none") answer=\"\(run.answerPreview)\""
            }.joined()
    }
}

// MARK: - The suite

/// The proof that a live model uses skills: given a task that fits a skill,
/// the model loads that skill.
///
/// Each sample is a task in the words of a user. It names no skill and no
/// tool. The agent mounts the skills library of the root package
/// (`Tests/Fixtures/skills/`), so the model sees the catalog in the
/// description of the `skills` tool and the rules in the instructions. What
/// the model does with that is the result. The mechanical path — the tool
/// mounts, the catalog is in the description, `use skill` gives the text —
/// is proved in the root package by `SkillsLibraryTests`, which cannot tell
/// what a model chooses.
///
/// **It is fast because it stops at the decision.** A run cancels the turn
/// as soon as a `use skill` call reaches the wire. The gate is one sample
/// with one run on the shipped standard model, and it asks for a skill, thus
/// the load is the first move: about 15 seconds after the model loads.
///
/// **It is repeatable because it decodes greedy.** With sampling, one sample
/// loaded its skill in 7 of 7 runs and then in 0 of 1, thus a red gate said
/// nothing about the code. Greedy, a red gate is a change of the code, of a
/// description or of the instructions.
///
/// Run the gate with:
///
/// ```sh
/// swift test --package-path IntegrationTests --filter SkillTriggerTests
/// ```
@Suite(
    .serialized,
    .timeLimit(.minutes(15)))
struct SkillTriggerTests {
    /// Runs the selected samples and asserts the bar for each one.
    @Test("A live model loads the skill that fits the task")
    func aLiveModelLoadsTheSkillThatFitsTheTask() async throws {
        let subject = try await skillTriggerHost.makeSubject()
        for sample in skillTriggerSamples {
            var runs: [SkillTriggerRun] = []
            for _ in 0..<skillTriggerRepeats {
                runs.append(try await subject.run(sample: sample))
            }
            let rate = SkillTriggerRate(sample: sample, runs: runs)
            // The rate is the result of this suite, thus it goes to the
            // reader whether the bar passes or fails.
            print("SKILL TRIGGER \(rate.line)")
            let message: Comment = """
                the model loaded `\(sample.expectedSkillID ?? "(none)")` for \
                `\(sample.name)` in \(rate.rate) of the runs, under the floor \
                \(skillTriggerFloor): \(rate.line)
                """
            #expect(rate.rate >= skillTriggerFloor, message)
        }
    }
}

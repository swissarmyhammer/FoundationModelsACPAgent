import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter

/// What one sample run observed: which skills the model loaded, and how the
/// turn ended.
struct SkillTriggerRun: Sendable {
    /// The sample that was driven.
    let sample: SkillTriggerSample

    /// The ids the model loaded with `use skill`, in call order.
    let loadedSkillIDs: [String]

    /// How many `skills` calls of any operation the model made.
    let skillsCallCount: Int

    /// The stop reason of the turn, or `nil` when the deadline passed.
    let stopReason: StopReason?

    /// The wall-clock seconds of the turn.
    let elapsedSeconds: Double

    /// The title of every tool call the wire carried, which names the tool.
    /// A run that saw no `skills` call says here what it did see instead.
    let toolTitlesSeen: [String]

    /// The start of the text the model wrote in the turn. A run that loaded
    /// no skill says here what the model did instead.
    let answerPreview: String

    /// Whether the run did what the sample asks: the expected skill is
    /// loaded, or no skill is loaded when the sample expects none.
    var passed: Bool {
        guard let expected = sample.expectedSkillID else {
            return loadedSkillIDs.isEmpty
        }
        return loadedSkillIDs.contains(expected)
    }
}

/// The model of the standard slot of a live run.
///
/// The default is the standard model the agent ships with
/// (`ProfileConfiguration.defaultStandard`), because the proof that matters is
/// that the shipped model uses skills. The test follows a change of that
/// default with no edit. `ACP_AGENT_SKILL_TRIGGER_MODEL` pins another model.
let skillTriggerModel: String = {
    let variable = "ACP_AGENT_SKILL_TRIGGER_MODEL"
    let value = ProcessInfo.processInfo.environment[variable]
    guard let shipped = ProfileConfiguration.defaultStandard.first?.stringValue else {
        preconditionFailure("ProfileConfiguration.defaultStandard names no model")
    }
    return (value?.isEmpty == false ? value : nil) ?? shipped
}()

/// How long a run waits for the decision, from the environment.
///
/// The default is 300 seconds. A run stops at the decision, thus a long
/// deadline costs time only when the model loads no skill. The first run of
/// a process also pays the load of the model: on the CI machine on
/// 2026-09-21 the gate sample took 76 seconds, where a warm machine takes
/// 15. `ACP_AGENT_SKILL_TRIGGER_DECISION_SECONDS` raises or lowers the wait.
let decisionDeadlineFromEnvironment: Duration = {
    let variable = "ACP_AGENT_SKILL_TRIGGER_DECISION_SECONDS"
    guard let text = ProcessInfo.processInfo.environment[variable], let seconds = Int(text),
        seconds > 0
    else { return .seconds(300) }
    return .seconds(seconds)
}()

/// The live subject of the skill trigger gate: one composed agent, one
/// session for each sample, and a reading of the recorded transcript.
///
/// **What it measures.** Whether a real model, given a real task and the
/// catalog of the skills library, calls `{"op": "use skill", "id": "<id>"}`
/// for the skill that fits. The mechanical path is proved in the root
/// package (`SkillsLibraryTests`); nothing here would fail because a tool is
/// unmounted, and nothing there tells us what a model chooses.
struct SkillTriggerSubject {
    /// The milliseconds between two looks at the collector.
    private static let pollInterval: Duration = .milliseconds(20)

    /// How long one sample run waits for the decision of the model.
    ///
    /// The measurement is the FIRST move: does the model load a skill for
    /// this task? A run therefore stops at the decision — it cancels the
    /// turn as soon as a `use skill` call reaches the wire, and it cancels
    /// at this deadline when none does. A sample that no skill covers
    /// always waits the whole deadline, because nothing can end it early.
    ///
    /// Measured on 2026-09-19 with `mlx-community/Qwen3.8-27B-mxfp4`: the
    /// five covered tasks each made their `use skill` call inside the first
    /// minute of a turn that then ran for 202 to 297 seconds. Waiting for
    /// the idle terminator thus paid three to four minutes for a fact the
    /// first minute already held.
    static let decisionDeadline: Duration = decisionDeadlineFromEnvironment

    /// The user-layer `config.yaml`: the transcripts record under the user
    /// directory, outside the workspace, so a removed workspace keeps its
    /// transcript. The shell and the code context stay off, because no
    /// sample needs them and each one makes a turn slower.
    ///
    /// The standard slot is ``skillTriggerModel``, which is the shipped
    /// standard model unless `ACP_AGENT_SKILL_TRIGGER_MODEL` pins another
    /// one.
    static var userConfigYAML: String {
        """
        transcripts:
          location: home
        tools:
          shell: false
          codeContext: false
        profile:
          standard: ["\(skillTriggerModel)"]
        """
    }

    /// The wired harness of the run.
    let harness: AgentClientHarness

    /// The recorder of the notification sequence.
    let collector: UpdateCollector

    /// The user layer root, which holds the transcripts.
    let userDirectory: URL

    /// The skills library of the root package.
    ///
    /// - Parameter filePath: The calling file, which anchors the walk to the
    ///   repository root.
    /// - Returns: The library directory.
    static func libraryDirectory(fromFile filePath: StaticString = #filePath) -> URL {
        var candidate = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while candidate.path != "/" {
            let library = candidate.appendingPathComponent("Tests/Fixtures/skills", isDirectory: true)
            if FileManager.default.fileExists(atPath: library.path) {
                return library
            }
            candidate = candidate.deletingLastPathComponent()
        }
        preconditionFailure("no ancestor of \(filePath) holds Tests/Fixtures/skills")
    }

    /// Makes a fresh workspace whose project layer holds the skills library.
    ///
    /// - Returns: The workspace directory.
    /// - Throws: Whatever the copy throws.
    static func makeWorkspace() throws -> URL {
        let workspace = makeResolvedDirectory(label: "SkillTrigger-workspace")
        try FileManager.default.copyItem(
            at: libraryDirectory(),
            to: workspace.appendingPathComponent(".skills", isDirectory: true))
        return workspace
    }

    /// Drives one sample in its own session and reads what it loaded.
    ///
    /// - Parameter sample: The sample to drive.
    /// - Returns: What the run observed.
    /// - Throws: Whatever the session or the prompt throws.
    func run(sample: SkillTriggerSample) async throws -> SkillTriggerRun {
        let workspace = try Self.makeWorkspace()
        let response = try await harness.connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
        let sessionId = response.sessionId
        let start = ContinuousClock.now
        _ = try await harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: sessionId, text: sample.prompt))
        let decision = await Self.waitForDecision(
            collector: collector,
            sessionId: sessionId,
            deadline: ContinuousClock.now + Self.decisionDeadline)
        let elapsed = start.duration(to: ContinuousClock.now)
        // The turn goes on doing the work of the task, and the work is not
        // the measurement. Cancel it, and wait for the idle the cancel
        // gives, so the next sample starts on a quiet session.
        try await harness.connection.sessionCancel(
            CancelSessionNotification(sessionId: sessionId))
        let stopReason = await Self.waitForIdle(
            collector: collector,
            sessionId: sessionId,
            deadline: ContinuousClock.now + Self.cancelDeadline)
        await harness.flushPendingChunks()
        let answer = await Self.answerText(of: collector, sessionId: sessionId)
        return SkillTriggerRun(
            sample: sample,
            loadedSkillIDs: decision.loadedIDs,
            skillsCallCount: decision.skillsCallCount,
            stopReason: stopReason,
            elapsedSeconds: Double(elapsed.components.seconds),
            toolTitlesSeen: decision.toolTitlesSeen,
            answerPreview: String(answer.prefix(Self.answerPreviewLength)))
    }

    /// The characters of the answer that a report line shows.
    static let answerPreviewLength = 240

    /// The text the model wrote in one session, joined in wire order.
    ///
    /// - Parameters:
    ///   - collector: The recorder of the sequence.
    ///   - sessionId: The session to read.
    /// - Returns: The answer text, with its line breaks as spaces.
    private static func answerText(
        of collector: UpdateCollector, sessionId: SessionId
    ) async -> String {
        let chunks = await collector.updates.compactMap { notification -> String? in
            guard notification.sessionId == sessionId,
                case .agentMessageChunk(let chunk) = notification.update,
                case .text(let content) = chunk.content
            else { return nil }
            return content.text
        }
        return chunks.joined().replacingOccurrences(of: "\n", with: " ")
    }

    /// How long a run waits for the idle that its cancel gives.
    static let cancelDeadline: Duration = .seconds(600)

    /// What one run saw before it stopped: the ids the model loaded, and
    /// how many `skills` calls it made.
    struct SkillsDecision: Sendable {
        /// The ids of every `use skill` call, in call order.
        let loadedIDs: [String]

        /// The `skills` calls of any operation.
        let skillsCallCount: Int

        /// The title of every tool call the wire carried.
        let toolTitlesSeen: [String]
    }

    /// Waits for the first `use skill` call of one session, or for the
    /// deadline.
    ///
    /// The wire carries the name of each tool call in `title` and its
    /// arguments in `rawInput`, so a run reads the decision as it happens
    /// and does not wait for the recorded transcript at the end of a turn.
    ///
    /// - Parameters:
    ///   - collector: The recorder of the sequence.
    ///   - sessionId: The session to watch.
    ///   - deadline: The instant the wait gives up at.
    /// - Returns: What the run saw.
    private static func waitForDecision(
        collector: UpdateCollector, sessionId: SessionId, deadline: ContinuousClock.Instant
    ) async -> SkillsDecision {
        var decision = SkillsDecision(loadedIDs: [], skillsCallCount: 0, toolTitlesSeen: [])
        while ContinuousClock.now < deadline {
            decision = await skillsDecision(of: collector, sessionId: sessionId)
            if !decision.loadedIDs.isEmpty {
                return decision
            }
            let idle = await collector.updates.contains { notification in
                guard notification.sessionId == sessionId,
                    case .stateUpdate(.idle) = notification.update
                else { return false }
                return true
            }
            if idle {
                return decision
            }
            try? await Task.sleep(for: pollInterval)
        }
        return decision
    }

    /// The `skills` calls the wire carries for one session.
    ///
    /// - Parameters:
    ///   - collector: The recorder of the sequence.
    ///   - sessionId: The session to read.
    /// - Returns: The ids the model loaded, and the count of `skills` calls.
    private static func skillsDecision(
        of collector: UpdateCollector, sessionId: SessionId
    ) async -> SkillsDecision {
        var loadedIDs: [String] = []
        var callCount = 0
        var titles: [String] = []
        for notification in await collector.updates where notification.sessionId == sessionId {
            guard case .toolCallUpdate(let update) = notification.update,
                case .value(let title) = update.title
            else { continue }
            titles.append(title)
            guard title == "skills", case .value(let rawInput) = update.rawInput,
                case .object(let arguments) = rawInput
            else { continue }
            callCount += 1
            guard case .string(let operation)? = arguments["op"],
                operation.lowercased().contains("use"),
                case .string(let id)? = arguments["id"]
            else { continue }
            loadedIDs.append(id)
        }
        return SkillsDecision(
            loadedIDs: loadedIDs, skillsCallCount: callCount, toolTitlesSeen: titles)
    }

    /// Waits for the idle terminator of one session.
    ///
    /// - Parameters:
    ///   - collector: The recorder of the sequence.
    ///   - sessionId: The session to watch.
    ///   - deadline: The instant the wait gives up at.
    /// - Returns: The stop reason, or `nil` at the deadline.
    private static func waitForIdle(
        collector: UpdateCollector, sessionId: SessionId, deadline: ContinuousClock.Instant
    ) async -> StopReason? {
        while ContinuousClock.now < deadline {
            let reasons = await collector.updates.compactMap { notification -> StopReason? in
                guard notification.sessionId == sessionId,
                    case .stateUpdate(.idle(let idle)) = notification.update
                else { return nil }
                return idle.stopReason
            }
            if let reason = reasons.last {
                return reason
            }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }
}

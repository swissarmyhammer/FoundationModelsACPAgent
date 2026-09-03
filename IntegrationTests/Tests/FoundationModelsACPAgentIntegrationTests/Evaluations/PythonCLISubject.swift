import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter

@testable import FoundationModelsACPAgent

// MARK: - The subject wiring (plan.md §20.3, decided 2026-09-01)
//
// The subject drives the agent over ACP, end to end:
// `InMemoryTransport.pair()`, an `AgentSideConnection` around a real
// `RoutedACPAgent`, `SwiftUIACPClient.connect(over:)` on the other
// end, then `initialize` → `session/new(workspace)` → `session/prompt`,
// waiting for the idle terminator. It never calls the Router session
// directly: "working" means a Client can drive the Agent. The wiring
// rides `AgentClientHarness.makeRecording(agent:)`, the same harness
// every integration tier uses, so the recorder's notification list is
// the wire-side evidence.

/// The raw artifacts of one driven sample turn: the wire records, the
/// converged client state, and the recorded transcript.
struct PythonCLITurnRun {
    /// The sample's workspace — the session `cwd` and the confinement
    /// root.
    let workspace: URL

    /// The injected user layer root the transcripts record under.
    let userDirectory: URL

    /// The session the turn ran in.
    let sessionId: SessionId

    /// The stop reason of the turn's idle terminator, or `nil` when the
    /// deadline passed with no idle update.
    let stopReason: StopReason?

    /// Whether `ACPSessionState.turnState` converged to `.idle`.
    let turnStateIdle: Bool

    /// The stop reason `ACPSessionState.lastStopReason` converged to.
    let lastStopReason: StopReason?

    /// The recorder's notification list for this session, in arrival
    /// order.
    let notifications: [UpdateSessionNotification]

    /// The accumulated tool calls of `ACPSessionState.toolCalls`.
    let toolCalls: [ToolCallUpdate]

    /// The session's final token meter, or `nil` when none arrived.
    let usage: UsageUpdate?

    /// The session's recorded transcript events, in `(ts, seq)` order.
    let transcript: [TranscriptEvent]

    /// The session's recording root, resolved WHILE the workspace was
    /// on disk. `URL.standardizedFileURL` strips the `/private` prefix
    /// only for a path that exists, so a root recomputed after the
    /// workspace deletion would name a different slug directory.
    let recordingRoot: URL

    /// The resolved standard-slot model, from the session's
    /// `session.json` sidecar, or `nil` when the sidecar is absent.
    let resolvedModel: String?

    /// The wall-clock seconds from the prompt to the idle terminator.
    let elapsedSeconds: Double

    /// How many prompt turns the drive sent: the build prompt plus
    /// every continuation prompt.
    let turnCount: Int
}

/// One connected subject host: a recording harness around an agent,
/// with the `initialize` handshake done. A gated run makes one host
/// and drives every sample through it, so the resident model loads
/// once.
struct PythonCLISubjectHost {
    /// The number of milliseconds between two looks at the collector.
    private static let pollIntervalMilliseconds = 20

    /// The pause between two looks at the collector.
    private static let pollInterval: Duration = .milliseconds(pollIntervalMilliseconds)

    /// The user-layer `config.yaml` the subject writes: the transcripts
    /// record under the injected user directory, OUTSIDE the workspace,
    /// so deleting a graded workspace never deletes its transcript
    /// (plan.md §20.3: keep the transcripts of failed runs).
    static let userConfigYAML = """
        transcripts:
          location: home
        """

    /// The wired harness.
    let harness: AgentClientHarness

    /// The recorder of the raw notification sequence.
    let collector: UpdateCollector

    /// The injected user layer root: the user config and the recorded
    /// transcripts live under it.
    let userDirectory: URL

    /// Makes the user layer root of one host: a resolved temp
    /// directory carrying ``userConfigYAML``.
    ///
    /// Call it BEFORE constructing the agent, and hand the same
    /// directory to the agent and to ``make(agent:userDirectory:)``,
    /// so every session's configuration stack reads it.
    ///
    /// - Parameter label: The directory label of the calling suite.
    /// - Returns: The prepared user directory.
    /// - Throws: The write error.
    static func prepareUserDirectory(label: String) throws -> URL {
        let userDirectory = makeResolvedDirectory(label: label)
        try userConfigYAML.write(
            to: userDirectory.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        return userDirectory
    }

    /// Wires a recording harness around `agent` and completes the
    /// `initialize` handshake.
    ///
    /// - Parameters:
    ///   - agent: The agent under evaluation, constructed with
    ///     `userDirectory` injected.
    ///   - userDirectory: The prepared user layer root.
    /// - Returns: The connected host.
    /// - Throws: Whatever the handshake throws.
    static func make(
        agent: RoutedACPAgent, userDirectory: URL
    ) async throws -> PythonCLISubjectHost {
        let harness = await AgentClientHarness.makeRecording(agent: agent)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let collector = harness.collector
        guard let collector else {
            preconditionFailure("makeRecording always wires a collector")
        }
        return PythonCLISubjectHost(
            harness: harness, collector: collector, userDirectory: userDirectory)
    }

    /// Closes the wire.
    func close() async {
        await harness.close()
    }

    // MARK: - One sample turn

    /// The follow-up prompt of a continuation turn. A turn that ends
    /// on a malformed tool call (`RejectedToolCall`, common on small
    /// local models) fails with the `_error` stop reason, and the
    /// session stays usable — the continuation gives the model its
    /// next chance over the same transcript (plan.md §20.3: a real
    /// multi-turn build task).
    static let continuationPrompt = """
        Continue the task. Check what is already done, fix what \
        failed, and finish every remaining step. Then run the step 2 \
        snippet again and confirm the expected output.
        """

    /// Opens a session in `workspace`, drives up to `maxTurns` prompt
    /// turns — the build prompt, then ``continuationPrompt`` after
    /// every stop that is not `end_turn` — and returns the run's raw
    /// artifacts.
    ///
    /// - Parameters:
    ///   - prompt: The sample's build-task prompt.
    ///   - workspace: The fresh workspace, already on disk under
    ///     `/private/tmp`, so its `realpath` equals its written path —
    ///     the form the seatbelt sandbox matches (the 2026-08-31 card
    ///     correction).
    ///   - idleDeadline: How long ONE turn may run before the wait
    ///     gives up and reports a `nil` stop reason.
    ///   - maxTurns: The most prompt turns the drive sends.
    /// - Returns: The run's artifacts.
    /// - Throws: Whatever `session/new` or `session/prompt` throws.
    func runSample(
        prompt: String, workspace: URL, idleDeadline: Duration, maxTurns: Int = 1
    ) async throws -> PythonCLITurnRun {
        guard let cwd = AbsolutePath(rawValue: workspace.path) else {
            throw PythonCLISubjectError.invalidWorkspacePath(workspace.path)
        }
        let response = try await harness.connection.newSession(NewSessionRequest(cwd: cwd))
        let sessionId = response.sessionId
        let start = ContinuousClock.now
        var stopReason: StopReason?
        var turnCount = 0
        for turnIndex in 0..<max(maxTurns, 1) {
            let text = turnIndex == 0 ? prompt : Self.continuationPrompt
            if turnIndex > 0 {
                // The idle notification goes out before the agent
                // clears the turn, so a follow-up prompt waits for the
                // session to accept one (ScriptedTurnFixture records
                // the same rule).
                guard
                    await Self.waitForAvailability(
                        of: harness.agent, sessionId: sessionId,
                        deadline: ContinuousClock.now + Self.availabilityDeadline)
                else { break }
            }
            _ = try await harness.connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: sessionId, text: text))
            turnCount += 1
            stopReason = await Self.waitForSessionIdle(
                collector: collector,
                sessionId: sessionId,
                minimumIdleCount: turnCount,
                deadline: ContinuousClock.now + idleDeadline)
            guard let reason = stopReason, reason != .endTurn else { break }
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        await harness.flushPendingChunks()

        let converged = await Self.convergedState(of: harness, sessionId: sessionId)
        let notifications = await collector.updates.filter { $0.sessionId == sessionId }
        // Resolved while the workspace exists — see
        // `PythonCLITurnRun.recordingRoot`.
        let recordingRoot = Self.recordingRoot(workspace: workspace, userDirectory: userDirectory)
        let transcript = Self.recordedTranscript(
            sessionId: sessionId, workspace: workspace, userDirectory: userDirectory)
        return PythonCLITurnRun(
            workspace: workspace,
            userDirectory: userDirectory,
            sessionId: sessionId,
            stopReason: stopReason,
            turnStateIdle: converged.turnStateIdle,
            lastStopReason: converged.lastStopReason,
            notifications: notifications,
            toolCalls: converged.toolCalls,
            usage: converged.usage,
            transcript: transcript,
            recordingRoot: recordingRoot,
            resolvedModel: Self.resolvedModel(sessionId: sessionId, recordingRoot: recordingRoot),
            elapsedSeconds: Self.seconds(of: elapsed),
            turnCount: turnCount)
    }

    /// The number of seconds in ``availabilityDeadline``.
    private static let availabilityDeadlineSeconds = 10

    /// How long a follow-up prompt waits for the session to accept
    /// one after the previous turn's idle notification.
    private static let availabilityDeadline: Duration = .seconds(availabilityDeadlineSeconds)

    /// Polls the collector until the session's `minimumIdleCount`-th
    /// idle terminator arrives or the deadline passes.
    ///
    /// - Parameters:
    ///   - collector: The collector to poll.
    ///   - sessionId: The session whose idle to wait for.
    ///   - minimumIdleCount: How many idle updates of this session the
    ///     collector must hold — the ordinal of the turn being waited
    ///     for, so a later turn never matches an earlier terminator.
    ///   - deadline: The instant the wait gives up at.
    /// - Returns: The latest idle stop reason, or `nil` at the
    ///   deadline.
    private static func waitForSessionIdle(
        collector: UpdateCollector,
        sessionId: SessionId,
        minimumIdleCount: Int,
        deadline: ContinuousClock.Instant
    ) async -> StopReason? {
        while ContinuousClock.now < deadline {
            let idleReasons = await collector.updates.compactMap {
                notification -> StopReason? in
                guard notification.sessionId == sessionId,
                    case .stateUpdate(.idle(let idle)) = notification.update
                else { return nil }
                return idle.stopReason
            }
            if idleReasons.count >= minimumIdleCount {
                return idleReasons.last
            }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    /// Polls the agent until the session accepts a new prompt or the
    /// deadline passes.
    ///
    /// - Parameters:
    ///   - agent: The agent under evaluation.
    ///   - sessionId: The session to watch.
    ///   - deadline: The instant the wait gives up at.
    /// - Returns: Whether the session became available.
    private static func waitForAvailability(
        of agent: RoutedACPAgent, sessionId: SessionId, deadline: ContinuousClock.Instant
    ) async -> Bool {
        while ContinuousClock.now < deadline {
            if await agent.sessions[sessionId]?.availability == .idle {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    /// The converged observable state of one session, read on the main
    /// actor.
    @MainActor
    private static func convergedState(
        of harness: AgentClientHarness, sessionId: SessionId
    ) -> (
        turnStateIdle: Bool,
        lastStopReason: StopReason?,
        toolCalls: [ToolCallUpdate],
        usage: UsageUpdate?
    ) {
        guard let state = harness.client.sessions[sessionId] else {
            return (false, nil, [], nil)
        }
        let turnStateIdle: Bool
        if case .idle = state.turnState {
            turnStateIdle = true
        } else {
            turnStateIdle = false
        }
        return (turnStateIdle, state.lastStopReason, Array(state.toolCalls.values), state.usage)
    }

    // MARK: - The recorded transcript

    /// The recording root of one workspace under this host's `home`
    /// transcript location: `<userDirectory>/transcripts/<slug>/`.
    ///
    /// - Parameters:
    ///   - workspace: The session working directory.
    ///   - userDirectory: The injected user layer root.
    /// - Returns: The root directory.
    static func recordingRoot(workspace: URL, userDirectory: URL) -> URL {
        TranscriptLocation.home.recordingRoot(
            workingDirectory: workspace,
            name: subjectDotfolderName(),
            userDirectory: userDirectory)
    }

    /// The session's recorded events, read back through
    /// `TranscriptStore` — the same read side `session/list` serves.
    ///
    /// - Parameters:
    ///   - sessionId: The session whose events to read.
    ///   - workspace: The project the session recorded in.
    ///   - userDirectory: The injected user layer root.
    /// - Returns: The events, or an empty list when nothing recorded.
    private static func recordedTranscript(
        sessionId: SessionId, workspace: URL, userDirectory: URL
    ) -> [TranscriptEvent] {
        guard let sessionULID = ULID(ulidString: sessionId.rawValue) else {
            return []
        }
        let store = TranscriptStore(
            location: .home, name: subjectDotfolderName(), userDirectory: userDirectory)
        return (try? store.transcript(for: sessionULID, inProject: workspace)) ?? []
    }

    /// The slice of the `session.json` sidecar this eval reads. The
    /// sidecar's own stored properties are internal (plan.md §20.1's
    /// trap list), so the eval decodes the one key it needs.
    private struct SidecarModelSlice: Decodable {
        /// The concrete model reference the session ran against.
        let model: String
    }

    /// The resolved model of one recorded session, from its sidecar.
    ///
    /// - Parameters:
    ///   - sessionId: The recorded session.
    ///   - recordingRoot: The session's resolved recording root.
    /// - Returns: The model reference, or `nil` when the sidecar is
    ///   absent or does not decode.
    private static func resolvedModel(
        sessionId: SessionId, recordingRoot: URL
    ) -> String? {
        let sidecar =
            recordingRoot
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: sidecar) else {
            return nil
        }
        return (try? JSONDecoder().decode(SidecarModelSlice.self, from: data))?.model
    }

    /// The validated dotfolder name of the subject agent — the harness
    /// name, so the host and the agent always agree on the project
    /// dotfolder and the transcript layout.
    private static func subjectDotfolderName() -> DotfolderName {
        guard let name = try? DotfolderName(AgentClientHarness.dotfolderName) else {
            preconditionFailure("the harness dotfolder name is always valid")
        }
        return name
    }

    /// The number of attoseconds in one second — the scale of
    /// `Duration.components`.
    private static let attosecondsPerSecond: Double = 1e18

    /// `duration` in seconds, for the run stats.
    private static func seconds(of duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / Self.attosecondsPerSecond
    }
}

/// What the subject wiring refused.
enum PythonCLISubjectError: Error, Equatable {
    /// The workspace path did not form an `AbsolutePath` for
    /// `session/new`.
    case invalidWorkspacePath(String)
}

// MARK: - The evidence readers

extension PythonCLITurnRun {
    /// The wire kinds that carry the shell steps' streamed output:
    /// `tool_call_content_chunk`, or the landed terminal vocabulary
    /// (plan.md §11.8: "When the terminal stream lands, `shell` moves
    /// its bytes to `terminal_output_chunk` and the tool call carries
    /// a `terminal` reference"). The reading accepts either, and the
    /// TierTwoTests suite comment records the same landed-vocabulary
    /// note for its own card.
    private static let shellStreamUpdateKinds: [SessionUpdateKind] = [
        .toolCallContentChunk, .terminalOutputChunk, .terminalUpdate,
    ]

    /// The name of the code-mode session tool.
    private static let runCodeToolName = "runCode"

    /// The two tool-traffic readings of this run, for
    /// ``PythonCLIGraders/toolTraffic(evidence:)``.
    ///
    /// The transcript side reads the recorded `.toolCalls` events —
    /// each is encoded back to its JSON form, the durable shape on
    /// disk, because the payload's typed tool-call fields are internal
    /// to Router — and the shell run's completed report in the
    /// recorded `.toolOutput` segments (see
    /// ``completedShellEventCount(in:)`` for why the operation events
    /// alone cannot name the shell). The wire side reads the
    /// accumulated `runCode` calls and the streamed shell output
    /// kinds.
    var toolTrafficEvidence: PythonCLIToolTrafficEvidence {
        PythonCLIToolTrafficEvidence(
            transcriptRunCodeSnippets: Self.runCodeSnippets(in: transcript),
            transcriptCompletedShellEventCount: Self.completedShellEventCount(in: transcript),
            completedRunCodeCallCount: toolCalls.count { call in
                call.title == .value(Self.runCodeToolName) && call.status == .value(.completed)
            },
            shellStreamNotificationCount: notifications.count { notification in
                Self.shellStreamUpdateKinds.contains(notification.update.kind)
            })
    }

    /// The encoded payloads of the recorded `runCode` `.toolCalls`
    /// events.
    ///
    /// - Parameter transcript: The recorded events.
    /// - Returns: One JSON text per `runCode` tool-calls event.
    private static func runCodeSnippets(in transcript: [TranscriptEvent]) -> [String] {
        let encoder = JSONEncoder()
        return transcript.compactMap { event -> String? in
            guard event.kind == .toolCalls, let entry = event.entry,
                let encoded = try? encoder.encode(entry)
            else { return nil }
            let text = String(decoding: encoded, as: UTF8.self)
            guard text.contains(runCodeToolName) else { return nil }
            return text
        }
    }

    /// The journal op of a shell run, Multitool's "verb noun" spelling.
    private static let shellJournalOp = "execute shell"

    /// The completion word every settled run report carries.
    private static let completionMarker = "complete"

    /// The number of recorded events whose segments carry the shell
    /// run's completed report.
    ///
    /// The code-mode host stamps every `OperationEvent` with the outer
    /// `runCode` tool, so `TranscriptEvent.operationEvents` never names
    /// the shell directly. The shell run's settlement is durable all
    /// the same: the `wait` report rides a recorded `.toolOutput`
    /// segment carrying the shell journal op — `"execute shell"` — with
    /// its completion state and exit evidence. This reading counts
    /// those segments.
    ///
    /// - Parameter transcript: The recorded events.
    /// - Returns: The count.
    private static func completedShellEventCount(in transcript: [TranscriptEvent]) -> Int {
        transcript.count { event in
            guard let segments = event.entry?.segments else { return false }
            return segments.contains { segment in
                guard case .structure(_, _, let contentJSON) = segment else { return false }
                return contentJSON.contains(shellJournalOp)
                    && contentJSON.contains(completionMarker)
            }
        }
    }
}

// MARK: - Grading and cleanup

extension PythonCLISubjectHost {
    /// Grades one finished run with the four mechanical graders,
    /// assembles the produced outcome, and cleans up: the workspace is
    /// always deleted after grading, and the session's transcripts are
    /// deleted only when every verdict passed — a failed run keeps its
    /// transcripts for the post-mortem (plan.md §20.3).
    ///
    /// - Parameters:
    ///   - run: The finished run.
    ///   - expected: The sample's ground truth.
    /// - Returns: The produced outcome.
    static func gradedOutcome(
        of run: PythonCLITurnRun, expected: PythonCLIOutcome
    ) async -> PythonCLIOutcome {
        let pytestGreen = await PythonCLIGraders.pytestGreen(workspace: run.workspace)
        let cliRuns = await PythonCLIGraders.cliRuns(
            workspace: run.workspace,
            moduleName: expected.moduleName,
            arguments: expected.arguments,
            expectedOutput: expected.expectedOutput)
        let filesPresent = PythonCLIGraders.filesPresent(
            workspace: run.workspace, requiredFiles: expected.requiredFiles)
        let toolTraffic = PythonCLIGraders.toolTraffic(evidence: run.toolTrafficEvidence)

        var produced = expected
        produced.stopReason = run.stopReason.map { String(describing: $0) }
        produced.pytestGreen = pytestGreen
        produced.cliRuns = cliRuns
        produced.filesPresent = filesPresent
        produced.toolTraffic = toolTraffic
        produced.stats = PythonCLIRunStats(
            resolvedModel: run.resolvedModel,
            turnCount: run.turnCount,
            toolCallCount: run.toolCalls.count,
            notificationCount: run.notifications.count,
            usedTokens: run.usage?.used,
            contextSize: run.usage?.size,
            elapsedSeconds: run.elapsedSeconds)

        cleanUp(
            run: run,
            allPassed: pytestGreen.passed && cliRuns.passed && filesPresent.passed
                && toolTraffic.passed)
        return produced
    }

    /// Deletes the graded workspace, and the transcripts of a run
    /// whose every verdict passed. A failed run's transcripts stay,
    /// and their path is printed for the post-mortem. The root comes
    /// from the run — see `PythonCLITurnRun.recordingRoot` — never from
    /// a recomputation over the now-deleted workspace.
    private static func cleanUp(run: PythonCLITurnRun, allPassed: Bool) {
        try? FileManager.default.removeItem(at: run.workspace)
        if allPassed {
            try? FileManager.default.removeItem(at: run.recordingRoot)
        } else {
            print(
                "PythonCLIEvaluation kept the failed run's transcripts: \(run.recordingRoot.path)")
        }
    }
}

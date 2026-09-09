import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `AgentComposition` (cli-plan.md §5.10): the `ACP_AGENT_STUB_MODEL=1`
/// switch selects the deterministic echo model in place of the live
/// loader, the composition says so, and two runs of one prompt through
/// it give byte-identical text.
struct AgentCompositionTests {
    // MARK: - Constants

    /// The prompt of the two runs. The echo model answers with the prompt
    /// it received, so the answer text carries it.
    private static let promptText = "echo this back"

    /// The environment variable that roots the user configuration layer,
    /// injected so the composition never touches the real home directory.
    private static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The environment that selects the stub model, and nothing else.
    private static let stubEnvironment = [
        AgentComposition.stubModelVariable: AgentComposition.stubModelEnabledValue
    ]

    // MARK: - The switch

    /// The variable at its enabled value selects the stub; an absent
    /// variable, and any other value, select the live loader.
    @Test func theVariableSelectsTheStubModel() {
        #expect(AgentComposition.modelSource(environment: Self.stubEnvironment) == .stub)
        #expect(AgentComposition.modelSource(environment: [:]) == .live)
        #expect(
            AgentComposition.modelSource(environment: [AgentComposition.stubModelVariable: "0"])
                == .live)
    }

    /// The dotfolder name is the one the tier-3 fixture writes its user
    /// configuration under, and it is a valid name.
    @Test func theDotfolderNameIsValid() throws {
        let name = try DotfolderName(AgentComposition.dotfolderName)

        #expect(name.rawValue == "acp-agent")
    }

    // MARK: - The stub composition

    /// With the stub selected the composition returns the echo model, and
    /// two runs of one prompt give byte-identical text that carries the
    /// prompt. No weights load and no network is touched: the composition
    /// finishes inside the time limit on a clean machine.
    @Test(.timeLimit(.minutes(1)))
    func theStubCompositionEchoesByteIdenticalText() async throws {
        let configHome = makeResolvedDirectory(label: "AgentCompositionTests-config")
        let workspace = makeResolvedDirectory(label: "AgentCompositionTests-repo")
        var environment = Self.stubEnvironment
        environment[Self.configHomeVariable] = configHome.path

        let first = try await ComposedTurnFixture.answerText(
            environment: environment, workspace: workspace, prompt: Self.promptText)
        let second = try await ComposedTurnFixture.answerText(
            environment: environment, workspace: workspace, prompt: Self.promptText)

        #expect(!first.isEmpty)
        #expect(first.contains(Self.promptText))
        #expect(first == second)
    }

    // MARK: - The recorder of the composed router

    /// One turn of the composed agent writes
    /// `<recording root>/<sessionId>/transcript.jsonl`, and the file holds
    /// the events of that turn.
    ///
    /// The composition is the only shipped call site that builds the
    /// router, so it is the only place that can turn the recorder on. With
    /// no recordings directory the router holds the no-op sink, every
    /// event goes nowhere, and `--resume` has nothing to read.
    ///
    /// The assertion reads the recorded file. It never reads
    /// `sessions.jsonl`: that index is written by this package's own
    /// `SessionIndex`, on a path that never touches the recorder, so it
    /// stays correct while every event drops.
    @Test(.timeLimit(.minutes(1)))
    func theComposedTurnRecordsTheSessionTranscript() async throws {
        let configHome = makeResolvedDirectory(label: "AgentCompositionTests-record-config")
        let workspace = makeResolvedDirectory(label: "AgentCompositionTests-record-repo")
        var environment = Self.stubEnvironment
        environment[Self.configHomeVariable] = configHome.path

        let turn = try await ComposedTurnFixture.run(
            environment: environment, workspace: workspace, prompt: Self.promptText)

        let root = Self.recordingRoot(of: workspace)
        let file = RecordedTranscriptFile.fileURL(
            under: root, sessionId: turn.sessionId.rawValue)
        #expect(
            FileManager.default.fileExists(atPath: file.path),
            "no transcript stands at \(file.path)")
        let lines = try RecordedTranscriptFile.lines(under: root, sessionId: turn.sessionId)
        #expect(!lines.isEmpty)
        #expect(lines.contains { $0.kind == TranscriptEvent.Kind.session.rawValue })
    }

    /// The router the composition built records: a session of its resident
    /// profile writes a transcript under the root it was given.
    ///
    /// This case names the cause and not only the symptom. It goes around
    /// the agent's own session pipeline and drives the resolved profile
    /// itself, so a pass says the recorder of the composed router writes,
    /// and a failure says the router holds the no-op sink.
    @Test(.timeLimit(.minutes(1)))
    func theComposedRouterRecordsThroughItsResidentProfile() async throws {
        let configHome = makeResolvedDirectory(label: "AgentCompositionTests-router-config")
        let workspace = makeResolvedDirectory(label: "AgentCompositionTests-router-repo")
        var environment = Self.stubEnvironment
        environment[Self.configHomeVariable] = configHome.path
        let composed = try await AgentComposition.compose(
            workingDirectory: workspace, environment: environment)
        let root = Self.recordingRoot(of: workspace)

        let session = composed.agent.residentProfile.standard.makeSession(
            workingDirectory: workspace, recordingRoot: root)
        _ = try await session.respond(to: Self.promptText)
        await session.close()

        let file = RecordedTranscriptFile.fileURL(
            under: root, sessionId: session.id.description)
        #expect(
            FileManager.default.fileExists(atPath: file.path),
            "the composed router recorded nothing at \(file.path)")
    }

    /// The recording root of `workspace` under the CLI's own dotfolder
    /// name, which is the default `project` location (plan.md §4.1).
    ///
    /// - Parameter workspace: The session working directory.
    /// - Returns: The recording root.
    private static func recordingRoot(of workspace: URL) -> URL {
        RecordedTranscriptFile.projectRecordingRoot(
            of: workspace, dotfolderName: AgentComposition.dotfolderName)
    }
}

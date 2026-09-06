import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
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

        let first = try await Self.answerText(environment: environment, workspace: workspace)
        let second = try await Self.answerText(environment: environment, workspace: workspace)

        #expect(!first.isEmpty)
        #expect(first.contains(Self.promptText))
        #expect(first == second)
    }

    /// Composes the agent over `environment`, runs one turn of
    /// ``promptText`` in `workspace` through the in-process harness, and
    /// returns the agent text the turn streamed.
    ///
    /// - Parameters:
    ///   - environment: The environment the composition reads.
    ///   - workspace: The session working directory.
    /// - Returns: The streamed agent text, chunks joined in arrival order.
    /// - Throws: Whatever the composition, the handshake or the turn throws.
    private static func answerText(
        environment: [String: String], workspace: URL
    ) async throws -> String {
        let composed = try await AgentComposition.compose(
            workingDirectory: workspace, environment: environment)
        #expect(composed.modelSource == .stub)
        let harness = await AgentClientHarness.makeRecording(agent: composed.agent)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let session = try await harness.connection.newSession(
            NewSessionRequest(cwd: try #require(AbsolutePath(rawValue: workspace.path))))
        let collector = try #require(harness.collector)
        _ = try await harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: session.sessionId, text: promptText))
        let updates = try await ScriptedTurnFixture.waitForIdle(collector)
        await harness.close()
        return agentMessageText(in: updates)
    }
}

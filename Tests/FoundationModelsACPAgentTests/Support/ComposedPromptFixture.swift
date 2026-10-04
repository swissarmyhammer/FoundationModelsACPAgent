import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import acp_agent

/// One prompt against an agent the shared `AgentComposition` built
/// (cli-plan.md §5.10): compose over an environment and a working
/// directory, drive one prompt through the in-process harness, and give
/// back the text the prompt streamed.
///
/// The composition suite and the `acp` suite both drive a prompt this way,
/// and the `acp` suite drives one over each wire of §4, so the
/// composition and the drive stand in one place and cannot drift.
enum ComposedPromptFixture {
    /// What one composed prompt gave: the session it ran in, and the agent
    /// text it streamed.
    struct Outcome {
        /// The session the prompt opened and ran in.
        let sessionId: SessionId

        /// The streamed agent text, chunks joined in arrival order.
        let text: String
    }

    /// The environment variable that roots the user configuration layer,
    /// injected so no composition touches the real home directory.
    private static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The environment a suite composes the CLI agent over: the stub model,
    /// the user layer rooted at `configHome`, and the defaults layer of
    /// `StubAgentDefaultsLayer`, which turns the code context off for each
    /// session.
    ///
    /// - Parameter configHome: The directory the user layer roots under.
    /// - Returns: The environment.
    /// - Throws: The write error of the defaults layer.
    static func makeStubEnvironment(configHome: URL) throws -> [String: String] {
        try StubAgentDefaultsLayer.makeEnvironment(
            name: AgentComposition.dotfolderName,
            base: [
                AgentComposition.stubModelVariable: AgentComposition.stubModelEnabledValue,
                configHomeVariable: configHome.path,
            ])
    }

    /// Composes the agent over `environment`, runs `prompt` as one prompt
    /// in `workspace`, and returns the agent text the prompt streamed.
    ///
    /// - Parameters:
    ///   - environment: The environment the composition reads.
    ///   - workspace: The session working directory.
    ///   - prompt: The text of the one prompt.
    ///   - wire: The transport pair the prompt runs over. The in-process
    ///     pair by default.
    /// - Returns: The streamed agent text, chunks joined in arrival order.
    /// - Throws: Whatever the composition, the handshake or the prompt
    ///   throws.
    static func answerText(
        environment: [String: String],
        workspace: URL,
        prompt: String,
        wire: HarnessWire = .makeInMemory()
    ) async throws -> String {
        try await run(
            environment: environment, workspace: workspace, prompt: prompt, wire: wire
        ).text
    }

    /// Composes the agent over `environment` and runs `prompt` as one prompt
    /// in `workspace`.
    ///
    /// `environment` must select the stub model: the fixture asserts the
    /// composition took that path, so no weights load and no network is
    /// touched.
    ///
    /// - Parameters:
    ///   - environment: The environment the composition reads.
    ///   - workspace: The session working directory.
    ///   - prompt: The text of the one prompt.
    ///   - wire: The transport pair the prompt runs over. The in-process
    ///     pair by default.
    /// - Returns: The session the prompt ran in, and the text it streamed.
    /// - Throws: Whatever the composition, the handshake or the prompt
    ///   throws.
    static func run(
        environment: [String: String],
        workspace: URL,
        prompt: String,
        wire: HarnessWire = .makeInMemory()
    ) async throws -> Outcome {
        let composed = try await AgentComposition.compose(
            workingDirectory: workspace, environment: environment)
        #expect(composed.modelSource == .stub)
        let harness = await AgentClientHarness.makeRecording(agent: composed.agent, wire: wire)
        _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
        let session = try await harness.connection.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
        let collector = try #require(harness.collector)
        _ = try await harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: session.sessionId, text: prompt))
        let updates = try await ScriptedPromptFixture.waitForIdle(collector)
        await harness.close()
        return Outcome(sessionId: session.sessionId, text: ScriptedPromptFixture.agentText(in: updates))
    }
}

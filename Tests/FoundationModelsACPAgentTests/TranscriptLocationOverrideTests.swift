import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

@testable import FoundationModelsACPAgent

/// The transcript location that an in-process host gives in code:
/// `ComposedAgent.compose(transcriptLocation:)`.
///
/// Each case composes the agent over the stub model, as an in-process host
/// does, and drives it from the client end of the harness. A value that
/// is not `nil` must reach each session request, because each request
/// loads the configuration again from the files.
@Suite(.closesHarnesses) struct TranscriptLocationOverrideTests {
    /// The dotfolder name of the host in this suite.
    private static let dotfolderName = "transcript-override-host"

    /// The environment variable that roots the user configuration layer.
    /// The suite sets it, so no composition touches the real home
    /// directory.
    private static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The text of the one prompt of each session. The first prompt writes
    /// the index record, and a session with no prompt is not listable.
    private static let promptText = "record this session"

    /// The project `config.yaml` that names `directory` as the transcript
    /// location.
    ///
    /// - Parameter directory: The absolute directory the file names.
    /// - Returns: The file content.
    private static func transcriptsConfigYAML(naming directory: URL) -> String {
        "transcripts:\n  location: \(directory.path)\n"
    }

    /// One composed agent, driven by a recording harness that completed
    /// `initialize`.
    private struct ComposedFixture {
        /// The composition the harness serves.
        let composed: ComposedAgent

        /// The connected harness around ``composed``.
        let harness: AgentClientHarness

        /// The session working directory. It holds no `config.yaml` unless
        /// the case writes one.
        let workspace: URL

        /// Opens one session in ``workspace``, sends one prompt, and waits
        /// until `root` holds a recorded event of the session.
        ///
        /// The stub model records the session event only, and no response
        /// event, so the wait reads any event of the session.
        ///
        /// - Parameter root: The recording root the case expects the
        ///   session to record under.
        /// - Returns: The session id.
        /// - Throws: Whatever the wire calls or the waits throw.
        func recordOneSession(under root: URL) async throws -> SessionId {
            let session = try await harness.client.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
            let sessionId = await MainActor.run { session.sessionId }
            _ = try await harness.connection.prompt(
                AgentClientHarness.makePromptRequest(sessionId: sessionId, text: promptText))
            _ = try await ScriptedPromptFixture.waitForIdle(try #require(harness.collector))
            await ScriptedPromptFixture.waitForPromptsFinished(harness.agent, sessionId)
            try await ResumeSessionFixture.waitForJournal(of: sessionId, in: harness.agent)
            #expect(try !ResumeSessionFixture.recordedEvents(under: root, sessionId: sessionId).isEmpty)
            return sessionId
        }

        /// The default `project` recording root of ``workspace``.
        var projectRoot: URL {
            get throws {
                try projectRecordingRoot(of: workspace, dotfolderName: dotfolderName)
            }
        }
    }

    /// Composes the agent over the stub model, with an empty user layer,
    /// and wires an initialized harness around it.
    ///
    /// - Parameters:
    ///   - label: The directory label, so a leftover directory says where
    ///     it came from.
    ///   - transcriptLocation: The code override to compose with, or `nil`.
    ///   - projectConfigYAML: The project `config.yaml` to write before the
    ///     composition, or `nil` for none.
    /// - Returns: The fixture.
    /// - Throws: Whatever the composition, the file write or `initialize`
    ///   throws.
    private static func makeFixture(
        label: String,
        transcriptLocation: TranscriptLocation?,
        projectConfigYAML: String? = nil
    ) async throws -> ComposedFixture {
        let workspace = makeResolvedDirectory(label: "\(label)-repo")
        if let projectConfigYAML {
            try ConfigFileFixture.write(
                projectConfigYAML,
                in: workspace.appendingPathComponent(".\(dotfolderName)", isDirectory: true))
        }
        let environment = try StubAgentDefaultsLayer.makeEnvironment(
            name: dotfolderName,
            base: [configHomeVariable: makeResolvedDirectory(label: "\(label)-config").path])
        let composed = try await ComposedAgent.compose(
            name: DotfolderName(dotfolderName),
            workingDirectory: workspace,
            environment: environment,
            modelSource: .stub,
            transcriptLocation: transcriptLocation)
        let harness = await AgentClientHarness.makeRecording(agent: composed.agent)
        _ = try await harness.client.initialize(AgentClientHarness.makeInitializeRequest())
        return ComposedFixture(composed: composed, harness: harness, workspace: workspace)
    }

    /// With `.path(dir)` and no config file, a session records in `dir`,
    /// the project and the cross-project `session/list` both list it after
    /// its close, and `session/resume` restores it.
    @Test
    func aCodeLocationRecordsListsAndResumesWithNoConfigFile() async throws {
        let transcripts = makeResolvedDirectory(label: "TranscriptLocationOverrideTests-path")
        let fixture = try await Self.makeFixture(
            label: "TranscriptLocationOverrideTests-path", transcriptLocation: .path(transcripts))
        let connection = fixture.harness.connection

        let sessionId = try await fixture.recordOneSession(under: transcripts)
        _ = try await connection.closeSession(CloseSessionRequest(sessionId: sessionId))
        let projectList = try await connection.listSessions(
            ListSessionsRequest(cwd: AbsolutePath(rawValue: fixture.workspace.path)))
        let crossProjectList = try await connection.listSessions(ListSessionsRequest())
        _ = try await connection.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: fixture.workspace.path), sessionId: sessionId))
        let availability = await fixture.harness.agent.sessions[sessionId]?.availability
        await fixture.harness.close()

        #expect(fixture.composed.agent.transcriptLocation == .path(transcripts))
        #expect(projectList.sessions.map(\.sessionId) == [sessionId])
        #expect(crossProjectList.sessions.map(\.sessionId) == [sessionId])
        #expect(availability == .idle)
        #expect(
            FileManager.default.fileExists(
                atPath: transcripts.appendingPathComponent(sessionId.rawValue).path))
        #expect(!FileManager.default.fileExists(atPath: try fixture.projectRoot.path))
    }

    /// The code location wins over the `transcripts.location` of a project
    /// `config.yaml`.
    @Test
    func aCodeLocationWinsOverTheProjectConfigFile() async throws {
        let transcripts = makeResolvedDirectory(label: "TranscriptLocationOverrideTests-wins")
        let fileLocation = makeResolvedDirectory(label: "TranscriptLocationOverrideTests-file")
        let fixture = try await Self.makeFixture(
            label: "TranscriptLocationOverrideTests-wins",
            transcriptLocation: .path(transcripts),
            projectConfigYAML: Self.transcriptsConfigYAML(naming: fileLocation))

        let sessionId = try await fixture.recordOneSession(under: transcripts)
        await fixture.harness.close()

        #expect(fixture.composed.configuration.transcripts.location == .path(transcripts))
        #expect(
            FileManager.default.fileExists(
                atPath: transcripts.appendingPathComponent(sessionId.rawValue).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: fileLocation.appendingPathComponent(sessionId.rawValue).path))
    }

    /// With no code location, the `transcripts.location` of a project
    /// `config.yaml` stays in force.
    @Test
    func noCodeLocationKeepsTheProjectConfigFileValue() async throws {
        let fileLocation = makeResolvedDirectory(label: "TranscriptLocationOverrideTests-nil")
        let fixture = try await Self.makeFixture(
            label: "TranscriptLocationOverrideTests-nil",
            transcriptLocation: nil,
            projectConfigYAML: Self.transcriptsConfigYAML(naming: fileLocation))

        let sessionId = try await fixture.recordOneSession(under: fileLocation)
        await fixture.harness.close()

        #expect(fixture.composed.agent.transcriptLocation == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: fileLocation.appendingPathComponent(sessionId.rawValue).path))
    }
}

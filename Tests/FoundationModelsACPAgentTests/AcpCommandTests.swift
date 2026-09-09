import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The `acp` subcommand (cli-plan.md §4, §5.3, §5.10): the stdio server
/// over the shared composition.
///
/// Four claims stand here. The wire ends when stdin ends, because
/// plan.md §17 gives the agent no teardown handshake. Each session takes
/// its project layer from its own `session/new(cwd)`, and never from the
/// directory the process started in — the "two loads" rule of §5.10.
/// The answer does not depend on the transport, so `run` mode's
/// in-process pair and the `acp` mode's stdio pipes give one text. And a
/// turn over the stdio wire records its transcript, because both modes
/// compose one router (§4.1).
struct AcpCommandTests {
    // MARK: - Constants

    /// The prompt of the same-answer comparison. The echo model answers
    /// with the prompt it received, so the answer text carries it.
    private static let promptText = "echo this over both wires"

    /// The environment variable that roots the user configuration layer,
    /// injected so no composition touches the real home directory.
    private static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The environment that selects the stub model, and nothing else.
    private static let stubEnvironment = [
        AgentComposition.stubModelVariable: AgentComposition.stubModelEnabledValue
    ]

    /// The `compaction.toolOutputLimit` of the directory the process
    /// starts in. No session may resolve this one.
    private static let startDirectoryLimit = 111

    /// The `compaction.toolOutputLimit` of the first session's repository.
    private static let firstRepositoryLimit = 222

    /// The `compaction.toolOutputLimit` of the second session's
    /// repository.
    private static let secondRepositoryLimit = 333

    /// One framed line the inbound-end proof sends through the wrapper,
    /// to prove it forwards before it reports the end.
    private static let probeFrame = "{\"jsonrpc\":\"2.0\"}\n"

    // MARK: - Fixtures

    /// Writes a project-layer `config.yaml` under `directory` that sets
    /// `compaction.toolOutputLimit` to `limit`.
    ///
    /// The key is inert: it changes no model and no tool, so the value a
    /// session resolved says which project layer that session read, and
    /// nothing else.
    ///
    /// - Parameters:
    ///   - limit: The value to write.
    ///   - directory: The repository the project layer roots under.
    /// - Throws: The directory-creation or write error.
    private static func writeToolOutputLimit(_ limit: Int, under directory: URL) throws {
        try ConfigFileFixture.write(
            "compaction:\n  toolOutputLimit: \(limit)\n",
            in: directory.appendingPathComponent(
                ".\(AgentComposition.dotfolderName)", isDirectory: true))
    }

    /// The stub environment with its user layer rooted at a throwaway
    /// directory.
    ///
    /// - Parameter configHome: The directory the user layer roots under.
    /// - Returns: The environment.
    private static func stubEnvironment(configHome: URL) -> [String: String] {
        var environment = stubEnvironment
        environment[configHomeVariable] = configHome.path
        return environment
    }

    // MARK: - The stdin-EOF lifecycle (plan.md §17)

    /// The wrapper hands every inbound chunk on, and reports the end of
    /// the inbound stream once the peer closes its outgoing direction.
    /// That report is what ends the `acp` process at stdin EOF: the
    /// client owns the lifecycle, and there is no teardown handshake.
    @Test(.timeLimit(.minutes(1)))
    func theInboundEndIsReportedWhenTheStreamEnds() async throws {
        let (peer, agentEnd) = InMemoryTransport.pair()
        let transport = InboundEndTransport(wrapping: agentEnd)
        var inbound = transport.bytes.makeAsyncIterator()

        try await peer.write(Data(Self.probeFrame.utf8))
        let forwarded = try await inbound.next()
        #expect(forwarded.map { String(decoding: $0, as: UTF8.self) } == Self.probeFrame)

        peer.close()
        await transport.waitForInboundEnd()
        let afterEnd = try await inbound.next()

        #expect(afterEnd == nil)
    }

    // MARK: - The two loads (cli-plan.md §5.10)

    /// Two sessions against one composed agent resolve two project
    /// layers, each from its own `session/new(cwd)`, and neither takes
    /// the directory the process started in.
    ///
    /// The three directories carry three different values of one inert
    /// key, so each assertion names exactly one layer. The start-up load
    /// is asserted first, so "neither took the process working
    /// directory" rests on a value that layer really held.
    @Test(.timeLimit(.minutes(2)))
    func eachSessionResolvesItsOwnProjectLayer() async throws {
        let configHome = makeResolvedDirectory(label: "AcpCommandTests-config")
        let startDirectory = makeResolvedDirectory(label: "AcpCommandTests-start")
        let firstRepository = makeResolvedDirectory(label: "AcpCommandTests-repo-first")
        let secondRepository = makeResolvedDirectory(label: "AcpCommandTests-repo-second")
        try Self.writeToolOutputLimit(Self.startDirectoryLimit, under: startDirectory)
        try Self.writeToolOutputLimit(Self.firstRepositoryLimit, under: firstRepository)
        try Self.writeToolOutputLimit(Self.secondRepositoryLimit, under: secondRepository)
        let environment = Self.stubEnvironment(configHome: configHome)

        // Load one: the start-up load, keyed by the directory the process
        // started in. `acp` passes `processWorkingDirectory` here.
        let startLoad = try AgentComposition.makeConfigurationLoader(
            workingDirectory: startDirectory, environment: environment
        ).load()
        #expect(startLoad.configuration.compaction.toolOutputLimit == Self.startDirectoryLimit)

        let composed = try await AgentComposition.compose(
            workingDirectory: startDirectory, environment: environment)
        let agent = composed.agent
        _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())

        // Load two: one per session, keyed by the session's own cwd.
        let first = try await agent.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: firstRepository.path)))
        let second = try await agent.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: secondRepository.path)))

        let sessions = await agent.sessions
        let firstEntry = try #require(sessions[first.sessionId])
        let secondEntry = try #require(sessions[second.sessionId])
        #expect(firstEntry.configuration.compaction.toolOutputLimit == Self.firstRepositoryLimit)
        #expect(secondEntry.configuration.compaction.toolOutputLimit == Self.secondRepositoryLimit)
    }

    // MARK: - The same answer over either wire (cli-plan.md §4, §9)

    /// One prompt, one scripted model, two transports: the in-process
    /// pair `run` mode uses, and a pair of real pipes carrying the ndJSON
    /// framing `acp` mode speaks. The answer text is the same, byte for
    /// byte, because only the transport changes.
    @Test(.timeLimit(.minutes(2)))
    func bothWiresGiveTheSameAnswer() async throws {
        let configHome = makeResolvedDirectory(label: "AcpCommandTests-config")
        let workspace = makeResolvedDirectory(label: "AcpCommandTests-repo")
        let environment = Self.stubEnvironment(configHome: configHome)

        let inProcess = try await ComposedTurnFixture.answerText(
            environment: environment, workspace: workspace, prompt: Self.promptText,
            wire: .makeInMemory())
        let overPipes = try await ComposedTurnFixture.answerText(
            environment: environment, workspace: workspace, prompt: Self.promptText,
            wire: .makeStdioPipes())

        #expect(!inProcess.isEmpty)
        #expect(inProcess.contains(Self.promptText))
        #expect(inProcess == overPipes)
    }

    // MARK: - The recording of the stdio wire (plan.md §4.1)

    /// A turn over the stdio wire writes
    /// `<recording root>/<sessionId>/transcript.jsonl`.
    ///
    /// `run` and `acp` compose one router, so the recorder cannot be on in
    /// one mode and off in the other. The assertion reads the recorded
    /// file, and never `sessions.jsonl`: that index is written on a path
    /// that never touches the recorder.
    @Test(.timeLimit(.minutes(2)))
    func aTurnOverTheStdioWireRecordsTheSessionTranscript() async throws {
        let configHome = makeResolvedDirectory(label: "AcpCommandTests-record-config")
        let workspace = makeResolvedDirectory(label: "AcpCommandTests-record-repo")
        let environment = Self.stubEnvironment(configHome: configHome)

        let turn = try await ComposedTurnFixture.run(
            environment: environment, workspace: workspace, prompt: Self.promptText,
            wire: .makeStdioPipes())

        let root = RecordedTranscriptFile.projectRecordingRoot(
            of: workspace, dotfolderName: AgentComposition.dotfolderName)
        let file = RecordedTranscriptFile.fileURL(
            under: root, sessionId: turn.sessionId.rawValue)
        #expect(
            FileManager.default.fileExists(atPath: file.path),
            "no transcript stands at \(file.path)")
        #expect(!(try RecordedTranscriptFile.lines(under: root, sessionId: turn.sessionId)).isEmpty)
    }
}

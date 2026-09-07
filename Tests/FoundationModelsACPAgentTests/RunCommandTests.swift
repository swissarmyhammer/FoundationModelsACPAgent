import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The `run` subcommand (cli-plan.md §4, §5.4): one turn, in one process,
/// over `InMemoryTransport.pair()`.
///
/// Four claims stand here. A turn over the in-process pair gives the text
/// the model produced, so the pair carries a whole turn and not only a
/// handshake. `--resume` continues a recorded session through
/// `session/load`, and the run never asks for a working directory: the
/// stored session already has one, and it wins. `--cwd` selects WHICH
/// dotfolder stack the start-up load reads, so two directories with two
/// `config.yaml` files give two resolved configurations. And no file of
/// the CLI names the agent type outside the composition, which pins the
/// one architecture rule: the CLI reaches the agent through an ACP
/// connection, and only the transport changes.
struct RunCommandTests {
    // MARK: - Constants

    /// The prompt of the first turn of every test here.
    private static let promptText = "write a haiku"

    /// The prompt of the resumed turn, which differs from
    /// ``promptText`` so the answer names which turn produced it.
    private static let resumedPromptText = "write another haiku"

    /// The text the scripted model streams as its one delta.
    private static let scriptedAnswer = "an answer over the in-process pair"

    /// The deltas of a scripted answer that arrives in parts, so the
    /// byte-for-byte proof reads more than one chunk.
    private static let scriptedChunks = ["an answer ", "in three ", "parts"]

    /// The `compaction.trigger` of the first repository. The key is
    /// inert — it changes no model and no tool — so a resolved value
    /// names exactly one project layer and nothing else.
    private static let firstTrigger = 0.31

    /// The `compaction.trigger` of the second repository.
    private static let secondTrigger = 0.62

    /// The directory that holds the CLI's source files, under the
    /// repository root.
    private static let commandSourceDirectory = "Sources/acp-agent"

    /// The extension of a Swift source file.
    private static let swiftExtension = "swift"

    /// The one file of ``commandSourceDirectory`` that may name the agent
    /// type: it is the file that constructs the agent.
    private static let compositionFileName = "AgentComposition.swift"

    /// The agent type no other file of the CLI may name.
    private static let agentTypeName = "RoutedACPAgent"

    // MARK: - Fixtures

    /// Composes over a model that plays `script`, so a turn gives a text
    /// the test wrote (plan.md §20.1). Nothing downloads and nothing
    /// loads.
    ///
    /// - Parameters:
    ///   - script: The steps the model plays on every turn.
    ///   - label: The directory label, so a leftover directory says where
    ///     it came from.
    /// - Returns: The composition, over the stub model path.
    /// - Throws: Whatever the agent construction throws.
    private static func scriptedComposition(
        script: [ScriptedTurnStep], label: String
    ) async throws -> AgentComposition.Composed {
        try await composition(loader: makeScriptedModelLoader(script: script), label: label)
    }

    /// Composes over the resume-shaped model: every generating call
    /// appends real prompt, reasoning and response transcript entries, so
    /// the session is on disk and `session/load` can restore it.
    ///
    /// - Parameter label: The directory label, so a leftover directory
    ///   says where it came from.
    /// - Returns: The composition, over the stub model path.
    /// - Throws: Whatever the agent construction throws.
    private static func resumableComposition(
        label: String
    ) async throws -> AgentComposition.Composed {
        var loader = StubModelLoader()
        loader.makeLLMContainer = { _ in ResumeRecordingContainer() }
        return try await composition(loader: loader, label: label)
    }

    /// Composes an agent over `loader` under the CLI's own dotfolder
    /// name, with every root in a throwaway directory.
    ///
    /// - Parameters:
    ///   - loader: The model loader the agent resolves against.
    ///   - label: The directory label, so a leftover directory says where
    ///     it came from.
    /// - Returns: The composition, over the stub model path.
    /// - Throws: Whatever the agent construction throws.
    private static func composition(
        loader: any ModelLoader, label: String
    ) async throws -> AgentComposition.Composed {
        let agent = try await makeStubAgent(
            name: AgentComposition.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
            recordingsDirectory: makeResolvedDirectory(label: "\(label)-recordings"),
            userDirectory: makeResolvedDirectory(label: "\(label)-user"),
            loader: loader)
        return AgentComposition.Composed(
            agent: agent, modelSource: .stub, configuration: AgentConfiguration())
    }

    /// Parses `acp-agent run --cwd <workspace> <prompt>` over `fixture`'s
    /// workspace, the way the shell hands the arguments over.
    ///
    /// - Parameter fixture: The two-layer tree the run reads.
    /// - Returns: The parsed `run` command.
    /// - Throws: The parse error, or when the parse selects another
    ///   subcommand.
    private static func parseRun(in fixture: ConfigCommandFixture) throws -> AcpAgentCommand.Run {
        try #require(
            try AcpAgentCommand.parseAsRoot(["run", "--cwd", fixture.workspace.path, promptText])
                as? AcpAgentCommand.Run)
    }

    /// The id of the one session `composed`'s agent holds.
    ///
    /// - Parameter composed: The composition whose agent to read.
    /// - Returns: The one session id.
    /// - Throws: When the agent holds no session, or more than one.
    private static func oneSessionId(of composed: AgentComposition.Composed) async throws
        -> SessionId
    {
        let sessions = await composed.agent.sessions
        #expect(sessions.count == 1)
        return try #require(sessions.keys.first)
    }

    /// The Swift source files directly under `directory`, in name order.
    ///
    /// - Parameter directory: The directory to read.
    /// - Returns: The Swift files.
    /// - Throws: The directory-read error.
    private static func swiftFiles(under directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == swiftExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - One turn over the in-process pair (cli-plan.md §4)

    /// One turn over `InMemoryTransport.pair()` gives the text the model
    /// produced, and ends on `end_turn`. No subprocess and no pipe: one
    /// process holds the agent connection and the client connection.
    @Test(.timeLimit(.minutes(1)))
    func aTurnOverTheInProcessPairGivesTheScriptedAnswer() async throws {
        let workspace = makeResolvedDirectory(label: "RunCommandTests-turn-repo")
        let composed = try await Self.scriptedComposition(
            script: [.textDelta(Self.scriptedAnswer), .endTurn], label: "RunCommandTests-turn")
        let capture = try AnswerCapture(label: "RunCommandTests-turn-answer")

        let result = try await RunTurn.answer(
            of: composed,
            in: .new(workingDirectory: workspace),
            prompt: Self.promptText,
            into: capture.writer)

        #expect(try capture.text() == Self.scriptedAnswer)
        #expect(result.stopReason == .endTurn)
    }

    /// The bytes on the descriptor equal the scripted chunks joined,
    /// with nothing added and nothing removed (cli-plan.md §5.6). The
    /// model streams three deltas, so the proof reads a whole answer and
    /// not one chunk. This is what `acp-agent run "hi" > out.txt` puts
    /// in the file.
    @Test(.timeLimit(.minutes(1)))
    func theTurnWritesTheScriptedChunksByteForByte() async throws {
        let workspace = makeResolvedDirectory(label: "RunCommandTests-bytes-repo")
        let composed = try await Self.scriptedComposition(
            script: Self.scriptedChunks.map { .textDelta($0) } + [.endTurn],
            label: "RunCommandTests-bytes")
        let capture = try AnswerCapture(label: "RunCommandTests-bytes-answer")

        _ = try await RunTurn.answer(
            of: composed,
            in: .new(workingDirectory: workspace),
            prompt: Self.promptText,
            into: capture.writer)

        #expect(try capture.bytes() == Data(Self.scriptedChunks.joined().utf8))
    }

    /// `acp-agent run "<prompt>"` runs the whole turn and writes the
    /// answer to the descriptor. The stub model answers with the prompt
    /// it received, so the bytes carry the prompt.
    @Test(.timeLimit(.minutes(2)))
    func theRunWritesTheAnswerToTheDescriptor() async throws {
        let fixture = ConfigCommandFixture(label: "RunCommandTests-report")
        let capture = try AnswerCapture(label: "RunCommandTests-report-answer")

        _ = try await Self.parseRun(in: fixture)
            .perform(environment: fixture.stubEnvironment, into: capture.writer)

        #expect(try capture.text().contains(Self.promptText))
    }

    // MARK: - `--resume` through `session/load` (cli-plan.md §5.4)

    /// `--resume` continues the recorded session: the second turn runs in
    /// the id the first turn opened, and the run sends no working
    /// directory of its own — it reads the stored one, because the stored
    /// session already has one and it wins.
    @Test(.timeLimit(.minutes(2)))
    func resumeRunsTheSecondTurnInTheRecordedSession() async throws {
        let workspace = makeResolvedDirectory(label: "RunCommandTests-resume-repo")
        let composed = try await Self.resumableComposition(label: "RunCommandTests-resume")
        let first = try AnswerCapture(label: "RunCommandTests-resume-first")
        _ = try await RunTurn.answer(
            of: composed,
            in: .new(workingDirectory: workspace),
            prompt: Self.promptText,
            into: first.writer)
        let opened = try await Self.oneSessionId(of: composed)
        let capture = try AnswerCapture(label: "RunCommandTests-resume-second")

        let result = try await RunTurn.answer(
            of: composed,
            in: .resumed(opened),
            prompt: Self.resumedPromptText,
            into: capture.writer)

        #expect(try await Self.oneSessionId(of: composed) == opened)
        #expect(try capture.text().contains(Self.resumedPromptText))
        #expect(result.stopReason == .endTurn)
    }

    /// A `--resume` of an id no listed session carries is refused by
    /// name, and never degrades into a fresh session.
    @Test(.timeLimit(.minutes(1)))
    func resumeOfAnUnlistedSessionIsRefused() async throws {
        let composed = try await Self.scriptedComposition(
            script: [.textDelta(Self.scriptedAnswer), .endTurn],
            label: "RunCommandTests-unlisted")
        let unlisted = SessionId(rawValue: ULID().ulidString)
        let capture = try AnswerCapture(label: "RunCommandTests-unlisted-answer")

        await #expect(throws: UnknownResumedSessionError.self) {
            _ = try await RunTurn.answer(
                of: composed,
                in: .resumed(unlisted),
                prompt: Self.promptText,
                into: capture.writer)
        }
    }

    // MARK: - `--cwd` selects the stack (cli-plan.md §5.4, §5.10)

    /// `--cwd` selects WHICH dotfolder stack the start-up load reads: two
    /// directories with two `config.yaml` files give two resolved
    /// configurations, from one binary and one process.
    @Test(.timeLimit(.minutes(2)))
    func cwdSelectsTheConfigurationTheRunLoads() async throws {
        let first = ConfigCommandFixture(label: "RunCommandTests-first")
        let second = ConfigCommandFixture(label: "RunCommandTests-second")
        try first.writeProjectCompactionTrigger(Self.firstTrigger)
        try second.writeProjectCompactionTrigger(Self.secondTrigger)

        let firstComposed = try await Self.parseRun(in: first)
            .compose(environment: first.stubEnvironment)
        let secondComposed = try await Self.parseRun(in: second)
            .compose(environment: second.stubEnvironment)

        #expect(firstComposed.configuration.compaction.trigger == Self.firstTrigger)
        #expect(secondComposed.configuration.compaction.trigger == Self.secondTrigger)
    }

    // MARK: - The one architecture rule (cli-plan.md §4)

    /// The composition is the only file of the CLI that names the agent
    /// type. Every other file reaches the agent through an ACP
    /// connection, and only the transport changes between the modes. A
    /// direct call would make the later socket mode a rewrite, and would
    /// stop the CLI proving the protocol.
    @Test func onlyTheCompositionNamesTheAgentType() throws {
        let directory = try PackageRoot.directory()
            .appendingPathComponent(Self.commandSourceDirectory, isDirectory: true)
        let sources = try Self.swiftFiles(under: directory)
        #expect(!sources.isEmpty)

        let naming = try sources
            .filter { try String(contentsOf: $0, encoding: .utf8).contains(Self.agentTypeName) }
            .map(\.lastPathComponent)

        #expect(naming == [Self.compositionFileName])
    }
}

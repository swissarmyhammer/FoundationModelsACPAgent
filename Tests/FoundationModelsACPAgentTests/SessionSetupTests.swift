import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The `session/new` composition pipeline (plan.md §7.1 and §4.2): the ACP
/// session id is the root Router session's ULID, the per-cwd config layer
/// shapes each session's tool roster, the project registry records the cwd,
/// and the session index stays empty until the first recorded activity.
@Suite struct SessionSetupTests {
    /// The JSON-RPC wire value of "invalid params".
    private static let invalidParamsWireValue = -32602

    /// The name of the standalone skills tool in the composed roster.
    private static let skillsToolName = "skills"

    /// A cwd string that is not absolute, so the agent must refuse it.
    private static let relativeCwd = "relative/path"

    // MARK: Harness

    /// Makes a stub agent that records durably under a throwaway
    /// recordings root, with the user layer at `userDirectory`, and runs
    /// `initialize` so the order rule passes.
    ///
    /// - Parameter userDirectory: The injected user layer root.
    /// - Returns: The initialized agent.
    /// - Throws: Whatever the construction or the handshake throws.
    private static func makeInitializedAgent(userDirectory: URL) async throws -> RoutedACPAgent {
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "SessionSetupTests-cache"),
            recordingsDirectory: makeResolvedDirectory(label: "SessionSetupTests-recordings"),
            userDirectory: userDirectory)
        _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())
        return agent
    }

    /// The `session/new` request for `cwd`, with no additional directories
    /// and no client MCP servers.
    ///
    /// - Parameter cwd: The session working directory.
    /// - Returns: The request.
    /// - Throws: When `cwd.path` is not an absolute path.
    private static func makeNewSessionRequest(cwd: URL) throws -> NewSessionRequest {
        NewSessionRequest(cwd: try #require(AbsolutePath(rawValue: cwd.path)))
    }

    /// The project-local transcripts root of `cwd`, the default
    /// `transcripts.location` (plan.md §4.1).
    ///
    /// - Parameter cwd: The session working directory.
    /// - Returns: `<cwd>/.<name>/transcripts/`.
    private static func projectTranscriptsRoot(of cwd: URL) -> URL {
        cwd
            .appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true)
            .appendingPathComponent(
                TranscriptLocation.transcriptsDirectoryName, isDirectory: true)
    }

    // MARK: Identity (§4.2)

    /// The sessionId parses as a ULID, names the Router session directory
    /// on disk, and the response carries the one model-slot config
    /// option (plan.md §15).
    @Test(.timeLimit(.minutes(1)))
    func sessionIdIsARouterULIDAndNamesTheSessionDirectory() async throws {
        let userDirectory = makeResolvedDirectory(label: "SessionSetupTests-user")
        let cwd = makeResolvedDirectory(label: "SessionSetupTests-repo")
        let agent = try await Self.makeInitializedAgent(userDirectory: userDirectory)

        let response = try await agent.newSession(Self.makeNewSessionRequest(cwd: cwd))

        #expect(ULID(ulidString: response.sessionId.rawValue) != nil)
        #expect(response.configOptions?.map(\.configId) == [ConfigOptions.modelOptionId])

        let sessionDirectory = Self.projectTranscriptsRoot(of: cwd)
            .appendingPathComponent(response.sessionId.rawValue, isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: sessionDirectory.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue)

        let entry = try #require(await agent.sessions[response.sessionId])
        #expect(entry.availability == .idle)
        #expect(entry.session.id.description == response.sessionId.rawValue)
        #expect(entry.transcriptDirectory.path == sessionDirectory.path)
        #expect(entry.workingDirectory.path == cwd.path)
        #expect(entry.additionalRoots.isEmpty)
        #expect(!entry.instructions.isEmpty)
    }

    // MARK: Absolute-cwd validation

    /// A relative cwd string is refused with the JSON-RPC invalid-params
    /// error before any composition runs.
    @Test func aRelativeCwdIsRefusedWithInvalidParams() {
        do {
            _ = try SessionSetup.validatedWorkingDirectory(path: Self.relativeCwd)
            Issue.record("expected an invalidParams error")
        } catch {
            #expect(error.code == .invalidParams)
        }
    }

    /// Over the wire, `session/new` with a relative cwd answers the
    /// JSON-RPC invalid-params error, never a session.
    @Test(.timeLimit(.minutes(1)))
    func aRelativeCwdOverTheWireAnswersInvalidParams() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = try await Self.makeInitializedAgent(
            userDirectory: makeResolvedDirectory(label: "SessionSetupTests-user"))
        let agentConnection = await AgentSideConnection(stream: agentEnd) { _ in agent }
        let frames = NDJSONCodec.frames(from: clientEnd.bytes, logger: .disabled)

        let request: FoundationModelsACP.JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("session/new"),
            "params": .object(["cwd": .string(Self.relativeCwd)]),
        ])
        try await clientEnd.write(NDJSONCodec.encode(request))

        var iterator = frames.makeAsyncIterator()
        let frame = try #require(try await iterator.next())
        guard case .message(.object(let fields)) = frame,
            case .object(let error) = fields["error"] ?? .null
        else {
            Issue.record("expected an error response, got \(frame)")
            return
        }
        #expect(error["code"] == .number(Double(Self.invalidParamsWireValue)))
        #expect(await agent.sessions.isEmpty)

        await agentConnection.close()
        clientEnd.close()
    }

    // MARK: Concurrent sessions with per-cwd config (§2.2, §7.1)

    /// Two sessions at once in two repos read two project layers: the repo
    /// whose config disables skills mounts no skills tool, while the plain
    /// repo mounts it.
    @Test(.timeLimit(.minutes(1)))
    func twoConcurrentSessionsReadDifferentProjectLayerConfig() async throws {
        let userDirectory = makeResolvedDirectory(label: "SessionSetupTests-user")
        let repoWithSkillsOff = makeResolvedDirectory(label: "SessionSetupTests-repo-skills-off")
        let plainRepo = makeResolvedDirectory(label: "SessionSetupTests-repo-plain")

        let dotfolder = repoWithSkillsOff.appendingPathComponent(
            ".\(AgentClientHarness.dotfolderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfolder, withIntermediateDirectories: true)
        try "tools:\n  skills: false\n".write(
            to: dotfolder.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)

        let agent = try await Self.makeInitializedAgent(userDirectory: userDirectory)
        let skillsOff = try await agent.newSession(
            Self.makeNewSessionRequest(cwd: repoWithSkillsOff))
        let plain = try await agent.newSession(Self.makeNewSessionRequest(cwd: plainRepo))

        let entries = await agent.sessions
        #expect(Set(entries.keys) == [skillsOff.sessionId, plain.sessionId])

        let skillsOffEntry = try #require(entries[skillsOff.sessionId])
        let plainEntry = try #require(entries[plain.sessionId])
        #expect(!skillsOffEntry.surface.tools.map(\.name).contains(Self.skillsToolName))
        #expect(plainEntry.surface.tools.map(\.name).contains(Self.skillsToolName))
        #expect(skillsOffEntry.configuration.tools.skills == .disabled)
        #expect(plainEntry.configuration.tools.skills != .disabled)
    }

    // MARK: Registry now, index at first activity (§4.5, §9)

    /// After `session/new` alone, `projects.jsonl` holds the cwd and the
    /// recording root holds no `sessions.jsonl` record yet.
    @Test(.timeLimit(.minutes(1)))
    func sessionNewRegistersTheProjectAndWritesNoIndexRecord() async throws {
        let userDirectory = makeResolvedDirectory(label: "SessionSetupTests-user")
        let cwd = makeResolvedDirectory(label: "SessionSetupTests-repo")
        let agent = try await Self.makeInitializedAgent(userDirectory: userDirectory)

        _ = try await agent.newSession(Self.makeNewSessionRequest(cwd: cwd))

        let records = try ProjectRegistry(directory: userDirectory).projects()
        #expect(records.map(\.path) == [cwd.standardizedFileURL.path])

        let indexFile = Self.projectTranscriptsRoot(of: cwd)
            .appendingPathComponent(SessionIndex.indexFileName)
        #expect(!FileManager.default.fileExists(atPath: indexFile.path))
    }

    // MARK: The derived compaction budget (§2.4)

    /// The non-default `compaction:` values the budget test writes.
    private static let configuredTrigger = 0.75

    /// The non-default fold target of the same section.
    private static let configuredTarget = 0.25

    /// The hard ceiling of the same section.
    private static let configuredHardCeiling = 0.875

    /// The tool-output cap, in tokens, of the same section.
    private static let configuredToolOutputLimit = 2048

    /// The slice of the recorded `session.json` sidecar the budget test
    /// reads. The sidecar's own stored properties are internal, so the
    /// test decodes only the keys it needs.
    private struct SidecarBudgetSlice: Decodable {
        /// The recorded configuration envelope's one read key.
        struct Configuration: Decodable {
            /// The recorded auto-compaction budget, or `nil` when the
            /// session was made with `budget: nil`.
            let budget: TokenBudget?
        }

        /// The configuration envelope, or `nil` for a recording made
        /// before the envelope existed.
        let configuration: Configuration?
    }

    /// A session made with a config `compaction:` section carries the
    /// derived budget: `session/new` builds `TokenBudget` from the
    /// section's fractions and the resolved standard-slot context, and
    /// the recorded sidecar carries it (plan.md §2.4).
    @Test(.timeLimit(.minutes(1)))
    func sessionNewDerivesTheBudgetFromTheCompactionSection() async throws {
        let userDirectory = makeResolvedDirectory(label: "SessionSetupTests-user")
        let cwd = makeResolvedDirectory(label: "SessionSetupTests-repo-compaction")
        let dotfolder = cwd.appendingPathComponent(
            ".\(AgentClientHarness.dotfolderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfolder, withIntermediateDirectories: true)
        try """
            compaction:
              trigger: \(Self.configuredTrigger)
              target: \(Self.configuredTarget)
              hardCeiling: \(Self.configuredHardCeiling)
              toolOutputLimit: \(Self.configuredToolOutputLimit)
            """.write(
                to: dotfolder.appendingPathComponent(ConfigurationLoader.configFileName),
                atomically: true, encoding: .utf8)
        let agent = try await Self.makeInitializedAgent(userDirectory: userDirectory)

        let response = try await agent.newSession(Self.makeNewSessionRequest(cwd: cwd))

        let sidecarFile = Self.projectTranscriptsRoot(of: cwd)
            .appendingPathComponent(response.sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("session.json")
        let slice = try JSONDecoder().decode(
            SidecarBudgetSlice.self, from: Data(contentsOf: sidecarFile))
        let budget = try #require(slice.configuration?.budget)
        #expect(budget.limit == agent.residentProfile.standard.contextTokens)
        #expect(budget.trigger == Self.configuredTrigger)
        #expect(budget.target == Self.configuredTarget)
        #expect(budget.hardCeiling == Self.configuredHardCeiling)
        #expect(budget.toolOutputLimit == Self.configuredToolOutputLimit)
    }

    // MARK: The resident profile outlives sessions (§1)

    /// The agent holds the profile strongly, so a second sequential
    /// `session/new` still vends — `makeSession` traps when the owning
    /// profile was released, and a successful second session proves it
    /// was not.
    @Test(.timeLimit(.minutes(1)))
    func theProfileStaysAliveAcrossTwoSequentialSessions() async throws {
        let userDirectory = makeResolvedDirectory(label: "SessionSetupTests-user")
        let cwd = makeResolvedDirectory(label: "SessionSetupTests-repo")
        let agent = try await Self.makeInitializedAgent(userDirectory: userDirectory)

        let first = try await agent.newSession(Self.makeNewSessionRequest(cwd: cwd))
        let second = try await agent.newSession(Self.makeNewSessionRequest(cwd: cwd))

        #expect(first.sessionId != second.sessionId)
        #expect(ULID(ulidString: second.sessionId.rawValue) != nil)
    }
}

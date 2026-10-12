import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The `session/new` composition pipeline: the ACP
/// session id is the root Router session's ULID, the per-cwd config layer
/// shapes each session's tool roster, the project registry records the cwd,
/// and the session index stays empty until the first recorded activity.
@Suite struct SessionSetupTests {
    /// The name of the standalone skills tool in the composed roster.
    private static let skillsToolName = "skills"

    /// A cwd string that is not absolute, so the agent must refuse it.
    private static let relativeCwd = "relative/path"

    /// An `additionalDirectories` entry that is not absolute, so the
    /// agent must refuse it too.
    private static let relativeAdditionalDirectory = "relative/extra"

    /// The `reason` every relative-path refusal reports in `data`.
    static let mustBeAbsoluteReason = "must be absolute"

    /// The `reason` a refusal reports for a request path that does not
    /// exist.
    static let doesNotExistReason = "does not exist"

    /// The `reason` a refusal reports for a request path that holds a file
    /// and not a directory.
    static let notADirectoryReason = "is not a directory"

    /// The name of the plain file the existence check test writes in place
    /// of a directory.
    private static let plainFileName = "plain.txt"

    /// The name of the directory the existence check tests never create.
    private static let missingDirectoryName = "missing"

    /// The JSON-RPC version every wire frame declares.
    private static let jsonrpcVersion = "2.0"

    /// The request id the raw `session/new` frame carries.
    private static let newSessionRequestId = 1.0

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
    private static func makeNewSessionRequest(cwd: URL) -> NewSessionRequest {
        NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path))
    }

    /// The project-local transcripts root of `cwd`, the default
    /// `transcripts.location`.
    ///
    /// - Parameter cwd: The session working directory.
    /// - Returns: `<cwd>/.<name>/transcripts/`.
    private static func projectTranscriptsRoot(of cwd: URL) -> URL {
        cwd
            .appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true)
            .appendingPathComponent(
                TranscriptLocation.transcriptsDirectoryName, isDirectory: true)
    }

    // MARK: Identity

    /// The sessionId parses as a ULID, names the Router session directory
    /// on disk, and the response carries the one model-slot config
    /// option, a `select` over the `standard` and `flash` slots.
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

    // MARK: Absolute-path validation

    /// The `data` object a request-path refusal must carry for `field`.
    /// A relative-path refusal names the field and the reason. A
    /// missing-directory refusal also names the refused path. The ACP
    /// schema states the path rules in prose and names no validator, so
    /// this agent is the only judge, and the refusal must say which field
    /// failed and why. A test gives this value as the `data` of
    /// `InitializationTests.expectRequestError`.
    ///
    /// - Parameters:
    ///   - field: The request field the refusal names.
    ///   - reason: Why the path is refused. The default is the
    ///     relative-path reason.
    ///   - path: The refused path, or `nil` when the refusal does not
    ///     name it.
    /// - Returns: The expected `data` member.
    static func expectedRefusalData(
        naming field: SessionSetup.PathField,
        reason: String = SessionSetupTests.mustBeAbsoluteReason,
        path: URL? = nil
    ) -> FoundationModelsACP.JSONValue {
        var data: [String: FoundationModelsACP.JSONValue] = [
            "field": .string(field.rawValue),
            "reason": .string(reason),
        ]
        data["path"] = path.map { .string($0.path) }
        return .object(data)
    }

    /// Sends one raw `session/new` frame carrying `params` and answers
    /// with the JSON-RPC error object the agent replied with. The frame is
    /// raw so the assertion reads the wire form a real peer sees. The
    /// session table is asserted empty, because a refused request opens no
    /// session.
    ///
    /// - Parameter params: The `params` member of the request.
    /// - Returns: The fields of the response's `error` member.
    /// - Throws: Whatever the agent construction, the handshake, or the
    ///   frame read throws.
    private static func newSessionWireError(
        params: FoundationModelsACP.JSONValue
    ) async throws -> [String: FoundationModelsACP.JSONValue] {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = try await Self.makeInitializedAgent(
            userDirectory: makeResolvedDirectory(label: "SessionSetupTests-user"))
        let agentConnection = await AgentSideConnection(stream: agentEnd) { _ in agent }
        let frames = NDJSONCodec.frames(from: clientEnd.bytes, logger: .disabled)

        let request: FoundationModelsACP.JSONValue = .object([
            "jsonrpc": .string(Self.jsonrpcVersion),
            "id": .number(Self.newSessionRequestId),
            "method": .string(ACPMethod.sessionNew),
            "params": params,
        ])
        try await clientEnd.write(NDJSONCodec.encode(request))

        var iterator = frames.makeAsyncIterator()
        let frame = try #require(try await iterator.next())
        let errorFields: [String: FoundationModelsACP.JSONValue]? = {
            guard case .message(.object(let fields)) = frame,
                case .object(let error) = fields["error"] ?? .null
            else {
                return nil
            }
            return error
        }()
        #expect(await agent.sessions.isEmpty)

        await agentConnection.close()
        clientEnd.close()
        return try #require(errorFields, "expected an error response, got \(frame)")
    }

    /// A relative cwd string is refused with the JSON-RPC invalid-params
    /// error before any composition runs, and the refusal names the field
    /// that failed and why.
    @Test func aRelativeCwdIsRefusedWithInvalidParams() async {
        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: Self.expectedRefusalData(naming: .cwd)
        ) {
            _ = try SessionSetup.validatedWorkingDirectory(
                path: Self.relativeCwd, field: .cwd)
        }
    }

    /// A relative `additionalDirectories` entry is refused the same way,
    /// naming its own field. The wire decode carries every entry as sent,
    /// so a skip here would drop a confinement root the client asked for
    /// and never say so.
    @Test func aRelativeAdditionalDirectoryIsRefusedWithInvalidParams() async {
        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: Self.expectedRefusalData(naming: .additionalDirectories)
        ) {
            _ = try SessionSetup.additionalRoots(
                fromPaths: [Self.relativeAdditionalDirectory])
        }
    }

    /// Over the wire, `session/new` with a relative cwd answers the
    /// JSON-RPC invalid-params error naming `cwd`, never a session.
    @Test(.timeLimit(.minutes(1)))
    func aRelativeCwdOverTheWireAnswersInvalidParams() async throws {
        let error = try await Self.newSessionWireError(
            params: .object(["cwd": .string(Self.relativeCwd)]))

        #expect(error["code"] == .number(Double(InitializationTests.invalidParamsWireValue)))
        #expect(error["data"] == Self.expectedRefusalData(naming: .cwd))
    }

    /// Over the wire, a relative `additionalDirectories` entry beside an
    /// absolute cwd answers the same refusal, naming its own field.
    @Test(.timeLimit(.minutes(1)))
    func aRelativeAdditionalDirectoryOverTheWireNamesItsOwnField() async throws {
        let cwd = makeResolvedDirectory(label: "SessionSetupTests-repo")
        let error = try await Self.newSessionWireError(
            params: .object([
                "cwd": .string(cwd.path),
                "additionalDirectories": .array([
                    .string(Self.relativeAdditionalDirectory)
                ]),
            ]))

        #expect(error["code"] == .number(Double(InitializationTests.invalidParamsWireValue)))
        #expect(error["data"] == Self.expectedRefusalData(naming: .additionalDirectories))
    }

    // MARK: The existence check

    /// A cwd that does not exist fails the existence check, and the
    /// refusal names the field, the path and the reason.
    @Test func aMissingDirectoryFailsTheExistenceCheck() async {
        let missing = makeResolvedDirectory(label: "SessionSetupTests-missing")
            .appendingPathComponent(Self.missingDirectoryName, isDirectory: true)

        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: Self.expectedRefusalData(
                naming: .cwd, reason: Self.doesNotExistReason, path: missing)
        ) {
            try SessionSetup.requireExistingDirectories(
                workingDirectory: missing, additionalRoots: [])
        }
    }

    /// An additional root that holds a file fails the existence check: a
    /// session directory must be a directory. The refusal names the
    /// field of the root, because the cwd passes.
    @Test func aFileInPlaceOfADirectoryFailsTheExistenceCheck() async throws {
        let cwd = makeResolvedDirectory(label: "SessionSetupTests-repo")
        let file = makeResolvedDirectory(label: "SessionSetupTests-file")
            .appendingPathComponent(Self.plainFileName)
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)

        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: Self.expectedRefusalData(
                naming: .additionalDirectories, reason: Self.notADirectoryReason, path: file)
        ) {
            try SessionSetup.requireExistingDirectories(
                workingDirectory: cwd, additionalRoots: [file])
        }
    }

    /// An existing cwd and an existing additional root pass the existence
    /// check.
    @Test func existingDirectoriesPassTheExistenceCheck() throws {
        let cwd = makeResolvedDirectory(label: "SessionSetupTests-existing")
        let root = makeResolvedDirectory(label: "SessionSetupTests-existing-extra")

        try SessionSetup.requireExistingDirectories(workingDirectory: cwd, additionalRoots: [root])
        #expect(SessionSetup.allDirectoriesExist(workingDirectory: cwd, additionalRoots: [root]))
    }

    /// `session/new` with a cwd that does not exist answers the
    /// invalid-params refusal, opens no session, and does not create the
    /// directory.
    @Test(.timeLimit(.minutes(1)))
    func sessionNewWithAMissingCwdIsRefusedAndCreatesNoDirectory() async throws {
        let missing = makeResolvedDirectory(label: "SessionSetupTests-missing-cwd")
            .appendingPathComponent(Self.missingDirectoryName, isDirectory: true)
        let agent = try await Self.makeInitializedAgent(
            userDirectory: makeResolvedDirectory(label: "SessionSetupTests-user"))

        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: Self.expectedRefusalData(
                naming: .cwd, reason: Self.doesNotExistReason, path: missing)
        ) {
            _ = try await agent.newSession(Self.makeNewSessionRequest(cwd: missing))
        }

        #expect(await agent.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    /// `session/new` with an `additionalDirectories` entry that does not
    /// exist answers the same refusal under its own field, and does not
    /// create the entry.
    @Test(.timeLimit(.minutes(1)))
    func sessionNewWithAMissingAdditionalDirectoryIsRefusedAndCreatesNoDirectory() async throws {
        let cwd = makeResolvedDirectory(label: "SessionSetupTests-repo")
        let missing = makeResolvedDirectory(label: "SessionSetupTests-missing-extra")
            .appendingPathComponent(Self.missingDirectoryName, isDirectory: true)
        let agent = try await Self.makeInitializedAgent(
            userDirectory: makeResolvedDirectory(label: "SessionSetupTests-user"))

        await InitializationTests.expectRequestError(
            .invalidParams, wireValue: InitializationTests.invalidParamsWireValue,
            data: Self.expectedRefusalData(
                naming: .additionalDirectories, reason: Self.doesNotExistReason, path: missing)
        ) {
            _ = try await agent.newSession(
                NewSessionRequest(
                    cwd: AbsolutePath(rawValue: cwd.path),
                    additionalDirectories: [AbsolutePath(rawValue: missing.path)]))
        }

        #expect(await agent.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: Concurrent sessions with per-cwd config

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

    // MARK: Registry now, index at first activity

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

    // MARK: The derived compaction budget

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
    /// the recorded sidecar carries it.
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

    // MARK: The repetition detection (Router RepetitionDetection)

    /// The non-default `repetition.windowTokens` the detection test writes.
    private static let configuredWindowTokens = 1024

    /// The non-default `repetition.recoveriesPerAnswer` of the same section.
    private static let configuredRecoveriesPerAnswer = 1

    /// The slice of the recorded `session.json` sidecar the detection test
    /// reads: the repetition detection of the configuration envelope.
    private struct SidecarRepetitionSlice: Decodable {
        /// The recorded configuration envelope's one read key.
        struct Configuration: Decodable {
            /// The recorded repetition detection of the session.
            let repetitionDetection: RepetitionDetection?
        }

        /// The configuration envelope, or `nil` for a recording made
        /// before the envelope existed.
        let configuration: Configuration?
    }

    /// A session made with a config `repetition:` section carries that
    /// detection: `session/new` passes the section to Router, and the
    /// recorded sidecar holds it.
    @Test(.timeLimit(.minutes(1)))
    func sessionNewPassesTheRepetitionSectionToTheSession() async throws {
        let userDirectory = makeResolvedDirectory(label: "SessionSetupTests-user")
        let cwd = makeResolvedDirectory(label: "SessionSetupTests-repo-repetition")
        let dotfolder = cwd.appendingPathComponent(
            ".\(AgentClientHarness.dotfolderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfolder, withIntermediateDirectories: true)
        try """
            repetition:
              windowTokens: \(Self.configuredWindowTokens)
              recoveriesPerAnswer: \(Self.configuredRecoveriesPerAnswer)
            """.write(
                to: dotfolder.appendingPathComponent(ConfigurationLoader.configFileName),
                atomically: true, encoding: .utf8)
        let agent = try await Self.makeInitializedAgent(userDirectory: userDirectory)

        let response = try await agent.newSession(Self.makeNewSessionRequest(cwd: cwd))

        let sidecarFile = Self.projectTranscriptsRoot(of: cwd)
            .appendingPathComponent(response.sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("session.json")
        let slice = try JSONDecoder().decode(
            SidecarRepetitionSlice.self, from: Data(contentsOf: sidecarFile))
        let detection = try #require(slice.configuration?.repetitionDetection)
        #expect(detection.windowTokens == Self.configuredWindowTokens)
        #expect(detection.recoveriesPerAnswer == Self.configuredRecoveriesPerAnswer)
        #expect(detection.isEnabled == RepetitionDetection.defaultIsEnabled)
    }

    // MARK: The resident profile outlives sessions

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

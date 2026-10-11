import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter
import Foundation
import Testing

@testable import FoundationModelsACPAgent

/// The tool catalog of this package. FoundationModelsAgents also has a type
/// named `ToolCatalog`, thus this suite names the type of this package
/// through this alias.
private typealias SurfaceCatalog = FoundationModelsACPAgent.ToolCatalog

/// The standalone `agents` tool of FoundationModelsAgents in the tool catalog
/// (task ^c4a6mwy): the mount beside the `skills` tool, the one skills
/// registry of the root session and the runs, the shared settle period, the
/// `start agent` answers, and the stop of the runs before the root session
/// closes.
///
/// Each test writes local agent folders `agents/<name>/AGENT.md` in the
/// project layer of a temporary working directory. No test reads a
/// marketplace agent.
@Suite struct AgentsToolTests {
    // MARK: - Constants

    /// The name of the `agents` tool.
    static let agentsToolName = "agents"

    /// The name of the `skills` tool.
    static let skillsToolName = "skills"

    /// The name of the Multitool `searchTools` session tool.
    static let searchToolsName = "searchTools"

    /// The name of the Multitool `runCode` session tool.
    static let runCodeName = "runCode"

    /// The folder of a layer root that holds the agent folders.
    static let agentsFolderName = "agents"

    /// The document of an agent folder.
    static let agentDocumentName = "AGENT.md"

    /// The agent whose run ends at once.
    static let quickAgent = "quick"

    /// The agent whose run waits for the test.
    static let slowAgent = "slow"

    /// The prompt of a quick run: the marker of its scripted branch.
    static let quickRunPrompt = "QUICK-RUN-MARKER"

    /// The prompt of a slow run: the marker of its scripted branch.
    static let slowRunPrompt = "SLOW-RUN-MARKER"

    /// The final text of a quick run.
    static let quickFinalText = "QUICK-FINAL-TEXT"

    /// The final text of a slow run.
    static let slowFinalText = "SLOW-FINAL-TEXT"

    /// The prompt of the root session that starts the quick run.
    static let rootQuickPrompt = "ROOT-QUICK-MARKER"

    /// The prompt of the root session that starts the slow run.
    static let rootSlowPrompt = "ROOT-SLOW-MARKER"

    /// A settle period that is much shorter than the default, so that a test
    /// can see that the root session uses the value of the context.
    static let shortSettlePeriod: TimeInterval = 0.5

    /// The longest time that a test waits for a state.
    static let waitTimeout: Duration = .seconds(5)

    /// The pause between two looks at a state.
    static let pollInterval: Duration = .milliseconds(20)

    /// The text that the pending envelope of the Router holds.
    static let pendingMarker = "pending"

    // MARK: - Fixtures

    /// Writes the agent folder `<cwd>/.agents/agents/<name>/AGENT.md`.
    ///
    /// - Parameters:
    ///   - name: The id of the agent, which is also the folder name.
    ///   - cwd: The session working directory.
    /// - Throws: The directory-creation or write error.
    static func writeAgent(named name: String, in cwd: URL) throws {
        let folder = cwd
            .appendingPathComponent(".\(SurfaceCatalog.agentsDotfolderName)", isDirectory: true)
            .appendingPathComponent(agentsFolderName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = "---\nname: \(name)\ndescription: The \(name) test agent.\n---\n\nDo the task.\n"
        try document.write(
            to: folder.appendingPathComponent(agentDocumentName, isDirectory: false),
            atomically: true, encoding: .utf8)
    }

    /// Makes a catalog context over a fresh working directory that holds
    /// the quick and the slow agent folders. The configuration is
    /// ``AgentConfiguration/withoutMarketplaces``, thus the skills source
    /// and the agent registry need no network.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - script: The steps of each scripted pass.
    ///   - inlineSettleGrace: The settle period of the context.
    ///   - configure: The mutation that shapes the configuration.
    /// - Returns: The context.
    /// - Throws: Whatever the fixture writes or the profile resolve throws.
    static func makeContext(
        label: String,
        script: [ScriptedPassStep] = [.endPass],
        inlineSettleGrace: TimeInterval = CatalogContext.defaultInlineSettleGrace,
        configure: (inout AgentConfiguration) -> Void = { _ in }
    ) async throws -> CatalogContext {
        let cwd = makeResolvedDirectory(label: "AgentsToolTests-\(label)")
        try writeAgent(named: quickAgent, in: cwd)
        try writeAgent(named: slowAgent, in: cwd)
        var configuration = AgentConfiguration.withoutMarketplaces
        configuration.tools.codeContext = .disabled
        configure(&configuration)
        return CatalogContext(
            workingDirectory: cwd,
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(label: "AgentsToolTests-\(label)-cache"),
                loader: makeScriptedModelLoader(script: script)),
            environment: [:],
            inlineSettleGrace: inlineSettleGrace)
    }

    /// The script of the `start agent` proofs: each run plays the branch of
    /// its prompt, and the root session starts the run that its prompt
    /// names.
    ///
    /// - Parameter hold: The hold that the slow run waits on.
    /// - Returns: The script.
    static func startAgentScript(hold: ScriptedHold) -> [ScriptedPassStep] {
        [
            .onPrompt(containing: quickRunPrompt, play: [.textDelta(quickFinalText), .endPass]),
            .onPrompt(
                containing: slowRunPrompt,
                play: [.holdUntilReleased(hold), .textDelta(slowFinalText), .endPass]),
            .onPrompt(
                containing: rootQuickPrompt,
                play: [startAgentCall(agent: quickAgent, prompt: quickRunPrompt), .endPass]),
            .onPrompt(
                containing: rootSlowPrompt,
                play: [startAgentCall(agent: slowAgent, prompt: slowRunPrompt), .endPass]),
            .endPass,
        ]
    }

    /// The scripted `start agent` call of the `agents` tool.
    ///
    /// - Parameters:
    ///   - agent: The id of the agent to start.
    ///   - prompt: The prompt of the run.
    /// - Returns: The tool-call step.
    static func startAgentCall(agent: String, prompt: String) -> ScriptedPassStep {
        .toolCall(
            name: agentsToolName,
            argumentsJSON: #"{"op":"start agent","name":"\#(agent)","prompt":"\#(prompt)"}"#)
    }

    /// Makes the root session over a surface, with the settle period of the
    /// surface.
    ///
    /// - Parameters:
    ///   - surface: The mounted surface.
    ///   - context: The context of the surface.
    /// - Returns: The root session.
    static func makeRootSession(surface: SessionSurface, context: CatalogContext) -> any RoutedSession {
        context.profile.standard.makeBudgetedSession(
            instructions: "",
            workingDirectory: context.workingDirectory,
            recordingRoot: makeResolvedDirectory(label: "AgentsToolTests-recordings"),
            tools: surface.tools,
            compaction: AgentConfiguration().compaction,
            repetition: AgentConfiguration().repetition,
            inlineSettleGrace: surface.inlineSettleGrace)
    }

    /// The text of each output of the `agents` tool in a transcript, in
    /// order.
    ///
    /// - Parameter transcript: The transcript of the root session.
    /// - Returns: The output texts.
    static func agentsToolOutputs(in transcript: Transcript) -> [String] {
        transcript.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry, output.toolName == agentsToolName else {
                return nil
            }
            return output.segments.map(segmentText).joined()
        }
    }

    /// The text of each prompt entry of a transcript, in order.
    ///
    /// - Parameter transcript: The transcript to read.
    /// - Returns: The prompt texts.
    static func promptTexts(in transcript: Transcript) -> [String] {
        transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.map(segmentText).joined()
        }
    }

    /// The text of one transcript segment: the text of a text segment, or
    /// the JSON of a structured segment, which is the form of a tool output
    /// that is a `String`. Each other segment gives the empty string.
    ///
    /// - Parameter segment: The segment.
    /// - Returns: Its text.
    static func segmentText(_ segment: Transcript.Segment) -> String {
        if case .text(let text) = segment {
            return text.content
        }
        if case .structure(let structure) = segment {
            return structure.content.jsonString
        }
        return ""
    }

    /// Waits until `condition` is true, or until ``waitTimeout``.
    ///
    /// - Parameter condition: The state to wait for.
    /// - Returns: `true` when the state came before the timeout.
    /// - Throws: `CancellationError` when the test is cancelled.
    static func waitUntil(_ condition: () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: waitTimeout)
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try await Task.sleep(for: pollInterval)
        }
        return await condition()
    }

    // MARK: - The mount

    /// A default context mounts the `agents` tool as a top-level tool after
    /// the `skills` tool, and the Multitool surface has no agents verb.
    @Test func aDefaultContextMountsTheAgentsToolBesideTheSkillsTool() async throws {
        let context = try await Self.makeContext(label: "mount")

        let surface = try await SurfaceCatalog.sessionSurface(context: context)
        let built = try await SurfaceCatalog.makeRegistry(context: context)

        #expect(surface.tools.map(\.name) == MountOrder.defaultToolNames)
        #expect(!built.registry.surface.entries.contains { $0.path.hasPrefix(Self.agentsToolName) })
        let agents = try #require(surface.tools.first { $0.name == Self.agentsToolName } as? AgentsTool)
        #expect(agents.agentNames.contains(Self.quickAgent))
        #expect(agents.agentNames.contains(Self.slowAgent))
        await surface.shutdown()
    }

    /// The scalar `agents: false` and the body `enabled: false` each give a
    /// session with no `agents` tool and no agent runner.
    @Test(arguments: [
        ToolSection<AgentsToolOptions>.disabled, .enabled(AgentsToolOptions(enabled: false)),
    ])
    func eachOffShapeOfTheAgentsSectionMountsNoAgentsTool(
        section: ToolSection<AgentsToolOptions>
    ) async throws {
        let context = try await Self.makeContext(label: "off") { configuration in
            configuration.tools.agents = section
        }

        let surface = try await SurfaceCatalog.sessionSurface(context: context)

        #expect(surface.tools.map(\.name) == MountOrder.withoutAgentsNames)
        #expect(surface.agents == nil)
    }

    /// The runs read the skills registry that the session gives the
    /// surface, and they get the Multitool session tools and the `skills`
    /// tool of the agent environment by name.
    @Test func theRunsGetTheSkillsToolOfTheOneRegistryAndTheSessionTools() async throws {
        let context = try await Self.makeContext(label: "skills")
        let skills = try #require(await SurfaceCatalog.makeSkillsSource(context: context))

        let surface = try await SurfaceCatalog.sessionSurface(context: context, skills: skills)

        let agents = try #require(surface.agents)
        #expect(agents.environment.tools.names == [Self.runCodeName, Self.searchToolsName, Self.skillsToolName])
        #expect(surface.tools.filter { $0.name == Self.skillsToolName }.count == 1)
        await surface.shutdown()
    }

    /// A factory of the run tools gives a new session tool of the name it
    /// asks for, and not the fallback tool, when the session tools build.
    /// The fallback here has an other name, thus a result that is the
    /// fallback fails the test.
    @Test func aFreshSessionToolHasTheAskedNameAndIsNotTheFallback() async throws {
        let context = try await Self.makeContext(label: "fresh")
        let built = try await SurfaceCatalog.makeRegistry(context: context)
        let selection = SurfaceCatalog.makeSearchSelection(profile: context.profile)
        let embedder = ProfileEmbedding(embedder: context.profile.embedding)
        let probes = try built.registry.makeSessionTools(selection: selection, embedder: embedder)
        let searchTools = try #require(probes.first { $0.name == Self.searchToolsName })

        let tool = AgentsComposition.freshSessionTool(
            named: Self.runCodeName, registry: built.registry, selection: selection,
            embedder: embedder, fallback: searchTools)

        #expect(tool.name == Self.runCodeName)
    }

    /// With the skills section off, the root session has no `skills` tool,
    /// and the runs get a `skills` tool over an empty skills registry.
    @Test func aSkillsSectionOffGivesTheRunsAnEmptySkillsRegistry() async throws {
        let context = try await Self.makeContext(label: "noskills") { configuration in
            configuration.tools.skills = .disabled
        }

        let surface = try await SurfaceCatalog.sessionSurface(context: context)

        #expect(surface.tools.map(\.name) == MountOrder.withoutSkillsNames)
        let agents = try #require(surface.agents)
        #expect(agents.environment.tools.names.contains(Self.skillsToolName))
        #expect(agents.environment.skills.metadata().isEmpty)
        await surface.shutdown()
    }

    // MARK: - The settle period

    /// The agent environment and the root session take the settle period of
    /// the catalog context, and the default is the settle period of the
    /// Router.
    @Test func theAgentEnvironmentAndTheSurfaceShareTheSettlePeriodOfTheContext() async throws {
        let context = try await Self.makeContext(
            label: "settle", inlineSettleGrace: Self.shortSettlePeriod)

        let surface = try await SurfaceCatalog.sessionSurface(context: context)

        #expect(surface.inlineSettleGrace == Self.shortSettlePeriod)
        #expect(surface.agents?.environment.inlineSettleGrace == Self.shortSettlePeriod)
        #expect(CatalogContext.defaultInlineSettleGrace == ToolMount.defaultInlineSettleGrace)
        await surface.shutdown()
    }

    /// The slice of a recorded `session.json` sidecar that the settle-period
    /// tests read. The stored properties of the sidecar are internal to
    /// Router, thus the tests decode only the key that they need.
    struct SidecarSettleSlice: Decodable {
        /// The configuration envelope of the sidecar.
        struct Configuration: Decodable {
            /// The settle period that the session got in its
            /// `SessionConfiguration`, in seconds.
            let inlineSettleGrace: TimeInterval?
        }

        /// The configuration envelope, or `nil` for a recording made before
        /// the envelope existed.
        let configuration: Configuration?
    }

    /// Makes an initialized agent over the stub profile whose sessions get
    /// `inlineSettleGrace`.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling test.
    ///   - inlineSettleGrace: The settle period of each session of the agent.
    /// - Returns: The agent, after `initialize`.
    /// - Throws: Whatever the construction or the handshake throws.
    static func makeAgent(label: String, inlineSettleGrace: TimeInterval) async throws -> RoutedACPAgent {
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "AgentsToolTests-\(label)-cache"),
            recordingsDirectory: makeResolvedDirectory(label: "AgentsToolTests-\(label)-recordings"),
            userDirectory: makeResolvedDirectory(label: "AgentsToolTests-\(label)-user"),
            inlineSettleGrace: inlineSettleGrace)
        _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())
        return agent
    }

    /// The recorded settle period of each session sidecar under the
    /// project-local transcripts root of `cwd`, in no fixed order.
    ///
    /// - Parameter cwd: The session working directory.
    /// - Returns: One value for each `session.json`, or `nil` for a sidecar
    ///   that records no settle period.
    /// - Throws: The read or the decode error of a sidecar.
    static func recordedSettlePeriods(under cwd: URL) throws -> [TimeInterval?] {
        let transcriptsRoot = cwd
            .appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true)
            .appendingPathComponent(TranscriptLocation.transcriptsDirectoryName, isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: transcriptsRoot, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == SessionIndex.sidecarFileName }
            .map { sidecar in
                try JSONDecoder().decode(SidecarSettleSlice.self, from: Data(contentsOf: sidecar))
                    .configuration?.inlineSettleGrace
            }
    }

    /// `session/new` gives the session that `makeBudgetedSession` makes the
    /// settle period of the agent in its `SessionConfiguration`: the sidecar
    /// of the root session records the short period, not the default. The
    /// test reads the sidecar, not a clock.
    @Test(.timeLimit(.minutes(1)))
    func aNewSessionGetsTheSettlePeriodOfTheAgentInItsConfiguration() async throws {
        let agent = try await Self.makeAgent(label: "settle-new", inlineSettleGrace: Self.shortSettlePeriod)
        let cwd = makeResolvedDirectory(label: "AgentsToolTests-settle-new-repo")

        _ = try await agent.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path)))

        let periods = try Self.recordedSettlePeriods(under: cwd)
        #expect(periods == [Self.shortSettlePeriod])
    }

    /// A model-slot switch gives the replacement session that
    /// `makeBudgetedSession` makes the settle period of the agent in its
    /// `SessionConfiguration`: after the switch, the sidecar of the root
    /// session and the sidecar of the replacement both record the short
    /// period. The test reads the sidecars, not a clock.
    @Test(.timeLimit(.minutes(1)))
    func aSlotSwitchGivesTheReplacementSessionTheSettlePeriodOfTheAgent() async throws {
        let agent = try await Self.makeAgent(label: "settle-switch", inlineSettleGrace: Self.shortSettlePeriod)
        let cwd = makeResolvedDirectory(label: "AgentsToolTests-settle-switch-repo")
        let response = try await agent.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path)))

        _ = try await agent.setSessionConfigOption(
            SetSessionConfigOptionRequest(
                configId: ConfigOptions.modelOptionId, sessionId: response.sessionId,
                value: .id(SessionConfigValueId(rawValue: ModelSlot.flash.rawValue))))

        let periods = try Self.recordedSettlePeriods(under: cwd)
        #expect(periods == [Self.shortSettlePeriod, Self.shortSettlePeriod])
    }

    // MARK: - The start agent answers

    /// A `start agent` call to a run that ends in the settle period gives
    /// the final message of the run as the output of the call, with no
    /// pending envelope, and no mail comes after it.
    @Test(.timeLimit(.minutes(1)))
    func aQuickRunGivesItsFinalMessageAsTheOutputOfTheCall() async throws {
        let hold = ScriptedHold()
        let context = try await Self.makeContext(
            label: "quick", script: Self.startAgentScript(hold: hold))
        let surface = try await SurfaceCatalog.sessionSurface(context: context)
        let session = Self.makeRootSession(surface: surface, context: context)

        _ = try await session.respond(to: Self.rootQuickPrompt, maxTokens: nil)

        let transcript = await session.transcript
        let output = try #require(Self.agentsToolOutputs(in: transcript).first)
        #expect(output.contains(Self.quickFinalText), "\(output)")
        #expect(!output.contains(Self.pendingMarker))
        #expect(!Self.promptTexts(in: transcript).contains { $0.contains(Self.quickFinalText) })
        hold.release()
        await surface.stopAgentRuns()
        await session.close()
        await surface.shutdown()
    }

    /// A `start agent` call to a run that continues after the settle period
    /// of the context gives the pending envelope. The final message of the
    /// run comes later as mail, one time. The test does not measure the wait
    /// with a clock, because a clock limit fails when the machine has a high
    /// load. These tests prove the settle period without a clock:
    /// ``theAgentEnvironmentAndTheSurfaceShareTheSettlePeriodOfTheContext()``
    /// for the agent environment and the surface,
    /// ``aNewSessionGetsTheSettlePeriodOfTheAgentInItsConfiguration()`` for
    /// the root session, and
    /// ``aSlotSwitchGivesTheReplacementSessionTheSettlePeriodOfTheAgent()``
    /// for the session after a slot switch.
    @Test(.timeLimit(.minutes(1)))
    func aSlowRunGoesToTheBackgroundAndItsFinalMessageComesAsMailOneTime() async throws {
        let hold = ScriptedHold()
        let context = try await Self.makeContext(
            label: "slow", script: Self.startAgentScript(hold: hold),
            inlineSettleGrace: Self.shortSettlePeriod)
        let surface = try await SurfaceCatalog.sessionSurface(context: context)
        let session = Self.makeRootSession(surface: surface, context: context)

        _ = try await session.respond(to: Self.rootSlowPrompt, maxTokens: nil)

        let output = try #require(Self.agentsToolOutputs(in: await session.transcript).first)
        #expect(!output.contains(Self.slowFinalText))
        #expect(output.contains(Self.pendingMarker), "\(output)")
        hold.release()
        let delivered = try await Self.waitUntil {
            Self.promptTexts(in: await session.transcript).contains { $0.contains(Self.slowFinalText) }
        }
        #expect(delivered)
        #expect(await session.awaitIdle())
        let mail = Self.promptTexts(in: await session.transcript).filter { $0.contains(Self.slowFinalText) }
        #expect(mail.count == 1)
        await session.close()
        await surface.shutdown()
    }

    // MARK: - The stop of the runs

    /// `stopAgentRuns()` cancels each run of the surface that is in
    /// operation.
    @Test(.timeLimit(.minutes(1)))
    func stopAgentRunsCancelsEachRunInOperation() async throws {
        let hold = ScriptedHold()
        let context = try await Self.makeContext(
            label: "stop", script: Self.startAgentScript(hold: hold))
        let surface = try await SurfaceCatalog.sessionSurface(context: context)
        let runner = try #require(surface.agents?.runner)
        let run = try await runner.start(Self.slowAgent, prompt: Self.slowRunPrompt)

        await surface.stopAgentRuns()

        #expect(run.state == .cancelled)
        hold.release()
        await surface.shutdown()
    }

    // MARK: - The run event observer (task ^zbcrex8)

    /// The completion token of a tool run of an agent run.
    static let agentToolRunToken = "01AGENTSTOOLRUNTOKEN000001"

    /// The open record of a tool run of an agent run, which Router of the
    /// agent run joined to an SDK call of the agent run.
    static let agentToolRunOpenRecord: SessionEvent = .toolInvocation(
        ToolInvocationRecord(
            tool: "shell", op: "execute command", correlationID: agentToolRunToken,
            sessionID: ULID.generate(), openedAt: Date(timeIntervalSince1970: 0)),
        toolCallID: "call-of-the-agent-run")

    /// The agent environment gives each session event of an agent run to the
    /// join table of the surface. The open record of a tool run of the agent
    /// run writes "no join" for that run while the agent run is in operation,
    /// so the terminal stream announces the run on its completion token and
    /// does not wait for the end of the agent run.
    @Test(.timeLimit(.minutes(1)))
    func theOpenRecordOfAToolRunOfAnAgentRunWritesItsEntryWhileTheRunIsInOperation() async throws {
        let hold = ScriptedHold()
        let context = try await Self.makeContext(
            label: "observer", script: Self.startAgentScript(hold: hold))
        let surface = try await SurfaceCatalog.sessionSurface(context: context)
        let agents = try #require(surface.agents)
        let run = try await agents.runner.start(Self.slowAgent, prompt: Self.slowRunPrompt)
        let observer = try #require(agents.environment.runEventObserver)
        surface.runCallJoins.openPrompt()

        observer(run, Self.agentToolRunOpenRecord)

        #expect(run.state == .running)
        #expect(
            surface.runCallJoins.announceToolCallId(for: Self.agentToolRunToken)
                == ToolCallId(rawValue: Self.agentToolRunToken))
        hold.release()
        await surface.shutdown()
    }

    /// `session/close` stops the agent runs of the session before the root
    /// session closes: when the close sweep of the root session finishes its
    /// event stream, the run is already cancelled.
    @Test(.timeLimit(.minutes(1)))
    func closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses() async throws {
        let hold = ScriptedHold()
        let cwd = makeResolvedDirectory(label: "AgentsToolTests-close-repo")
        try Self.writeAgent(named: Self.slowAgent, in: cwd)
        let fixture = try await ScriptedPromptFixture.make(
            script: Self.startAgentScript(hold: hold), label: "AgentsToolTests-close",
            workingDirectory: cwd)
        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        let runner = try #require(entry.surface.agents?.runner)
        let run = try await runner.start(Self.slowAgent, prompt: Self.slowRunPrompt)
        let events = await entry.session.streamSessionEvents()
        let stateAtRootClose = Task { () -> AgentRunState in
            for await _ in events {}
            return run.state
        }

        _ = try await fixture.harness.connection.closeSession(
            CloseSessionRequest(sessionId: fixture.sessionId))

        #expect(await stateAtRootClose.value == .cancelled)
        hold.release()
        await fixture.close()
    }
}

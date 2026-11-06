import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import InMemoryTracing
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The tool catalog of this package. FoundationModelsAgents also has a type
/// named `ToolCatalog`, thus this suite names the type of this package
/// through this alias.
private typealias SurfaceCatalog = FoundationModelsACPAgent.ToolCatalog

/// The standalone `agents` tool of FoundationModelsAgents in the tool catalog
/// (task ^c4a6mwy). This suite covers these points:
/// - The mount beside the `skills` tool.
/// - The one skills registry of the root session and the runs.
/// - The shared settle period.
/// - The `start agent` answers.
/// - The stop of the runs before the root session closes.
///
/// Each test writes local agent folders `agents/<name>/AGENT.md` in the
/// project layer of a temporary working directory. No test reads a
/// marketplace agent.
@Suite(.closesHarnesses) struct AgentsToolTests {
  // MARK: - Constants

  /// The name of the `agents` tool.
  static let agentsToolName = "agents"

  /// The tool call updates of the `agents` tool among some session updates.
  ///
  /// - Parameter updates: The session updates, from the wire or from a history.
  /// - Returns: The tool call updates that name the `agents` tool, in the order of the input.
  static func agentsCalls(in updates: [SessionUpdate]) -> [ToolCallUpdate] {
    updates.compactMap { update in
      if case .toolCallUpdate(let call) = update, call.name == .value(agentsToolName) {
        return call
      }
      return nil
    }
  }

  /// The name of the `skills` tool.
  static let skillsToolName = "skills"

  /// The name of the Multitool `searchTools` session tool.
  static let searchToolsName = "searchTools"

  /// The name of the Multitool `runCode` session tool.
  static let runCodeName = "runCode"

  /// The folder of a layer root that holds the agent folders.
  static let agentsFolderName = "agents"

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

  /// A settle period that is much shorter than the default.
  /// A test can thus see that the root session uses the value of the context.
  static let shortSettlePeriod: TimeInterval = 0.5

  /// The text that the pending envelope of the Router holds.
  static let pendingMarker = "pending"

  // MARK: - Fixtures

  /// The agent folder `<cwd>/.agents/agents/<name>`.
  ///
  /// - Parameters:
  ///   - name: The id of the agent, which is also the folder name.
  ///   - cwd: The session working directory.
  /// - Returns: The folder.
  private static func agentFolder(named name: String, in cwd: URL) -> URL {
    cwd
      .appendingPathComponent(".\(SurfaceCatalog.agentsDotfolderName)", isDirectory: true)
      .appendingPathComponent(agentsFolderName, isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
  }

  /// Deletes the agent folder `<cwd>/.agents/agents/<name>`, so the catalog has no such agent.
  ///
  /// - Parameters:
  ///   - name: The id of the agent, which is also the folder name.
  ///   - cwd: The session working directory.
  /// - Throws: The removal error.
  static func removeAgent(named name: String, in cwd: URL) throws {
    try FileManager.default.removeItem(at: agentFolder(named: name, in: cwd))
  }

  /// Writes the agent folder `<cwd>/.agents/agents/<name>/AGENT.md`.
  ///
  /// - Parameters:
  ///   - name: The id of the agent, which is also the folder name.
  ///   - cwd: The session working directory.
  ///   - tools: The value of the `tools` key of the agent, or `nil` for an agent with no such key.
  ///     A run gets the `agents` tool only with an explicit grant.
  ///   - disallowedTools: The value of the `disallowedTools` key of the agent, or `nil` for an
  ///     agent with no such key.
  /// - Throws: The directory-creation or write error.
  static func writeAgent(
    named name: String, in cwd: URL, tools: String? = nil, disallowedTools: String? = nil
  ) throws {
    let extraKeys = [tools.map { "tools: \($0)" }, disallowedTools.map { "disallowedTools: \($0)" }]
      .compactMap { $0 }
    try AgentFolderFixture.writeProjectAgent(id: name, in: cwd, extraKeys: extraKeys)
  }

  /// Makes a catalog context over a fresh working directory that holds
  /// the quick and the slow agent folders. The configuration is
  /// ``AgentConfiguration/withoutMarketplaces``, thus the skills source
  /// and the agent registry need no network.
  ///
  /// - Parameters:
  ///   - label: The directory label of the calling test.
  ///   - script: The steps of each scripted pass.
  ///   - loader: The model loader, or `nil` (the default) to play `script` in every pass.
  ///   - inlineSettleGrace: The settle period of the context.
  ///   - configure: The mutation that shapes the configuration.
  /// - Returns: The context.
  /// - Throws: Whatever the fixture writes or the profile resolve throws.
  static func makeContext(
    label: String,
    script: [ScriptedPassStep] = [.endPass],
    loader: StubModelLoader? = nil,
    inlineSettleGrace: TimeInterval = CatalogContext.defaultInlineSettleGrace,
    runClock: (any RunClock)? = nil,
    configure: (inout AgentConfiguration) -> Void = { _ in }
  ) async throws -> CatalogContext {
    let cwd = makeResolvedDirectory(label: "AgentsToolTests-\(label)")
    try writeAgent(named: quickAgent, in: cwd)
    try writeAgent(named: slowAgent, in: cwd)
    var configuration = AgentConfiguration.withoutMarketplaces
    configuration.tools.codeContext = .disabled
    configure(&configuration)
    let cacheDirectory = makeResolvedDirectory(label: "AgentsToolTests-\(label)-cache")
    let loader = loader ?? makeScriptedModelLoader(script: script)
    let profile =
      if let runClock {
        try await makeStubProfile(
          cacheDirectory: cacheDirectory, loader: loader, runClock: runClock)
      } else {
        try await makeStubProfile(cacheDirectory: cacheDirectory, loader: loader)
      }
    return CatalogContext(
      workingDirectory: cwd,
      configuration: configuration,
      profile: profile,
      settingsFolders: try SettingsFoldersFixture.make(label: "AgentsToolTests"),
      environment: [:],
      inlineSettleGrace: inlineSettleGrace)
  }

  /// The script of the `start agent` proofs. Each run plays the branch of
  /// its prompt. The root session starts the run that its prompt names.
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
  static func makeRootSession(surface: SessionSurface, context: CatalogContext) -> any RoutedSession
  {
    context.profile.standard.makeBudgetedSession(
      instructions: "",
      workingDirectory: context.workingDirectory,
      recordingRoot: makeResolvedDirectory(label: "AgentsToolTests-recordings"),
      tools: surface.tools,
      compaction: AgentConfiguration().compaction,
      repetition: AgentConfiguration().repetition,
      inlineSettleGrace: surface.inlineSettleGrace,
      transcriptReader: nil)
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

  /// The text of one transcript segment. A text segment gives its text.
  /// A structured segment gives its JSON. This is the form of a tool output
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

  // MARK: - The mount

  /// A default context mounts the `agents` tool as a top-level tool after
  /// the `skills` tool. The Multitool surface has no agents verb.
  @Test func aDefaultContextMountsTheAgentsToolBesideTheSkillsTool() async throws {
    let context = try await Self.makeContext(label: "mount")

    let surface = try await SurfaceCatalog.sessionSurface(context: context)
    let built = try await SurfaceCatalog.makeRegistry(context: context)

    #expect(surface.tools.map(\.name) == MountOrder.defaultToolNames)
    #expect(!built.registry.surface.entries.contains { $0.path.hasPrefix(Self.agentsToolName) })
    let agents = try #require(surface.tools.first { $0.name == Self.agentsToolName } as? AgentsTool)
    let agentNames = await agents.launchableAgents().map(\.name)
    #expect(agentNames.contains(Self.quickAgent))
    #expect(agentNames.contains(Self.slowAgent))
    await surface.shutdown()
  }

  /// The config cannot turn the `agents` tool off. The loader reads the
  /// scalar `agents: false` and the body `enabled: false`. Each one gives
  /// a session with the `agents` tool and an agent runner.
  @Test(arguments: ["agents: false", "agents:\n    enabled: false"])
  func aConfigThatTurnsTheAgentsToolOffStillMountsTheAgentsTool(entry: String) async throws {
    let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
      "tools:\n  \(entry)\n  skills:\n    marketplaces: []\n  codeContext: false\n")
    let context = try await Self.makeContext(label: "off") { configuration in
      configuration.tools = loaded.configuration.tools
    }

    let surface = try await SurfaceCatalog.sessionSurface(context: context)

    #expect(surface.tools.map(\.name) == MountOrder.defaultToolNames)
    #expect(surface.agents != nil)
    await surface.shutdown()
  }

  /// The runs read the skills registry that the session gives the
  /// surface. They get the Multitool session tools by name. They get the
  /// `skills` tool of the agent environment by name.
  @Test func theRunsGetTheSkillsToolOfTheOneRegistryAndTheSessionTools() async throws {
    let context = try await Self.makeContext(label: "skills")
    let skills = await SurfaceCatalog.makeSkillsSource(context: context)

    let surface = try await SurfaceCatalog.sessionSurface(context: context, skills: skills)

    let agents = try #require(surface.agents)
    #expect(
      agents.environment.tools.names == [
        Self.runCodeName, Self.searchToolsName, Self.skillsToolName,
      ])
    #expect(surface.tools.filter { $0.name == Self.skillsToolName }.count == 1)
    await surface.shutdown()
  }

  /// A factory of the run tools gives a new session tool. The tool has the
  /// name that the factory asks for. This happens when the session tools
  /// build. It does not give the fallback
  /// tool. The fallback here has an other name. Thus a result that is the
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

  /// The tool catalog of the runs builds no pair of session tools at the
  /// mount. Each pair builds the search index of the registry, and that
  /// build is the largest cost of a new session. The pair that the session
  /// mounted already proves that the build succeeds, so the catalog reads
  /// the names and the fallback from that pair. A selection factory is
  /// called once for each pair, thus the count shows the pairs.
  @Test func theRunToolsBuildNoPairOfSessionToolsAtTheMount() async throws {
    let context = try await Self.makeContext(label: "run-tools-pairs")
    let built = try await SurfaceCatalog.makeRegistry(context: context)
    let base = SurfaceCatalog.makeSearchSelection(profile: context.profile)
    let embedder = ProfileEmbedding(embedder: context.profile.embedding)
    let pairs = CallCounter()
    let counting: SearchToolsTool.SelectionFactory = { ids in
      pairs.record()
      return try base(ids)
    }
    let mounted = try built.registry.makeSessionToolsAndStaging(
      selection: counting, embedder: embedder
    ).tools

    let runTools = AgentsComposition.makeRunTools(
      registry: built.registry, selection: counting, embedder: embedder, mounted: mounted)

    #expect(pairs.count == 1)
    #expect(runTools.names == [Self.runCodeName, Self.searchToolsName])
  }

  // MARK: - The release of the mount

  /// Builds the surface of a session, shuts it down, and watches its runner.
  ///
  /// - Parameter label: The directory label of the calling test.
  /// - Returns: The watch of the runner.
  /// - Throws: Whatever the surface construction throws.
  private static func shutDownRunner(label: String) async throws -> WeakRunnerWatch {
    let context = try await makeContext(label: label)
    let surface = try await SurfaceCatalog.sessionSurface(context: context)
    let watch = WeakRunnerWatch(watching: surface.agents?.runner)
    await surface.shutdown()
    return watch
  }

  /// The runner of a session goes away when the surface of the session is
  /// shut down and dropped. A reference cycle from the join table to the
  /// runner keeps the runner, and the runner keeps its search over the
  /// agents, whose task holds the embedder. The model pool then keeps each
  /// model for ever, and the next live-model test cannot resolve.
  @Test func theRunnerOfASessionGoesAwayWithItsSurface() async throws {
    let watch = try await Self.shutDownRunner(label: "runner-release")

    #expect(try await watch.waitForRelease(), "something still holds the runner of the session")
  }

  // MARK: - The settle period

  /// The agent environment and the root session take the settle period of
  /// the catalog context. The default is the settle period of the Router.
  @Test func theAgentEnvironmentAndTheSurfaceShareTheSettlePeriodOfTheContext() async throws {
    let context = try await Self.makeContext(
      label: "settle", inlineSettleGrace: Self.shortSettlePeriod)

    let surface = try await SurfaceCatalog.sessionSurface(context: context)

    #expect(surface.inlineSettleGrace == Self.shortSettlePeriod)
    #expect(surface.agents?.environment.inlineSettleGrace == Self.shortSettlePeriod)
    #expect(CatalogContext.defaultInlineSettleGrace == ToolMount.defaultInlineSettleGrace)
    await surface.shutdown()
  }

  /// The slice of the recorded `index.md` of a session folder that the
  /// settle-period tests read. The stored properties of the record are
  /// internal to Router, thus the tests decode only the key that they need.
  struct RecordSettleSlice: Decodable {
    /// The configuration envelope of the record.
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
  static func makeAgent(label: String, inlineSettleGrace: TimeInterval) async throws
    -> RoutedACPAgent
  {
    let agent = try await makeStubAgent(
      name: AgentClientHarness.dotfolderName,
      cacheDirectory: makeResolvedDirectory(label: "AgentsToolTests-\(label)-cache"),
      recordingsDirectory: makeResolvedDirectory(label: "AgentsToolTests-\(label)-recordings"),
      userDirectory: makeResolvedDirectory(label: "AgentsToolTests-\(label)-user"),
      inlineSettleGrace: inlineSettleGrace)
    _ = try await agent.initialize(AgentClientHarness.makeInitializeRequest())
    return agent
  }

  /// The recorded settle period of each session record under the
  /// project-local transcripts root of `cwd`, in no fixed order.
  ///
  /// - Parameter cwd: The session working directory.
  /// - Returns: One value for each `index.md`, or `nil` for a record that
  ///   holds no settle period.
  /// - Throws: The walk, the read or the decode error of a record.
  static func recordedSettlePeriods(under cwd: URL) throws -> [TimeInterval?] {
    let transcriptsRoot =
      cwd
      .appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true)
      .appendingPathComponent(TranscriptLocation.transcriptsDirectoryName, isDirectory: true)
    return try RecordedSessionIndexFile.slices(under: transcriptsRoot, as: RecordSettleSlice.self)
      .map { $0.configuration?.inlineSettleGrace }
  }

  /// `session/new` gives the session that `makeBudgetedSession` makes the
  /// settle period of the agent in its `SessionConfiguration`. The record
  /// of the root session holds the short period, not the default. The
  /// test reads the record, not a clock.
  @Test
  func aNewSessionGetsTheSettlePeriodOfTheAgentInItsConfiguration() async throws {
    let agent = try await Self.makeAgent(
      label: "settle-new", inlineSettleGrace: Self.shortSettlePeriod)
    let cwd = makeResolvedDirectory(label: "AgentsToolTests-settle-new-repo")

    _ = try await agent.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path)))

    let periods = try Self.recordedSettlePeriods(under: cwd)
    #expect(periods == [Self.shortSettlePeriod])
  }

  /// A model-slot switch restores the session with the recorded
  /// configuration. After the switch, the one record of the session still
  /// holds the short settle period of the agent. The test reads the
  /// record, not a clock.
  @Test
  func aSlotSwitchKeepsTheSettlePeriodOfTheAgentInTheRecord() async throws {
    let agent = try await Self.makeAgent(
      label: "settle-switch", inlineSettleGrace: Self.shortSettlePeriod)
    let cwd = makeResolvedDirectory(label: "AgentsToolTests-settle-switch-repo")
    let response = try await agent.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path)))

    _ = try await agent.setSessionConfigOption(
      SetSessionConfigOptionRequest(
        configId: ConfigOptions.modelOptionId, sessionId: response.sessionId,
        value: .id(SessionConfigValueId(rawValue: ModelSlot.flash.rawValue))))

    let periods = try Self.recordedSettlePeriods(under: cwd)
    #expect(periods == [Self.shortSettlePeriod])
  }

  // MARK: - The start agent answers

  /// A `start agent` call to a run that ends in the settle period gives
  /// the final message of the run. This message is the output of the call.
  /// It gives no
  /// pending envelope. No mail comes after it.
  ///
  /// The settle period waits on a `ManualRunClock` that the test never
  /// advances. Thus the period cannot end before the quick run. On the real
  /// clock, a machine with a high load could end the period first.
  @Test
  func aQuickRunGivesItsFinalMessageAsTheOutputOfTheCall() async throws {
    let hold = ScriptedHold()
    let context = try await Self.makeContext(
      label: "quick", script: Self.startAgentScript(hold: hold), runClock: ManualRunClock())
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
  /// run comes later as mail, one time.
  ///
  /// The settle period is zero, on a `ManualRunClock` that the test never
  /// advances. Thus the call reaches the deadline of the period when it
  /// starts to wait. The held run cannot end before that. So the call
  /// gives the pending envelope in a fixed order, with no clock. When the
  /// held run ends, `awaitIdle()` waits for the open run. It also waits
  /// for the answer of its mail. These tests prove the settle period
  /// without a clock:
  /// - ``theAgentEnvironmentAndTheSurfaceShareTheSettlePeriodOfTheContext()``
  ///   for the agent environment and the surface,
  /// - ``aNewSessionGetsTheSettlePeriodOfTheAgentInItsConfiguration()``
  ///   for the root session, and
  /// - ``aSlotSwitchGivesTheReplacementSessionTheSettlePeriodOfTheAgent()``
  ///   for the session after a slot switch.
  @Test
  func aSlowRunGoesToTheBackgroundAndItsFinalMessageComesAsMailOneTime() async throws {
    let hold = ScriptedHold()
    try await Self.proveASlowRunSettlesAsMail(
      label: "slow", loader: makeScriptedModelLoader(script: Self.startAgentScript(hold: hold))
    ) {
      hold.release()
    }
  }

  /// The same proof as
  /// ``aSlowRunGoesToTheBackgroundAndItsFinalMessageComesAsMailOneTime()``,
  /// but the slow run waits at a `gate` step on a named pipe. The root
  /// session must go on and end while the run waits at the pipe, and the
  /// byte that the test writes into the pipe lets the run end (task
  /// ^js730ph).
  @Test(.timeLimit(.minutes(1)))
  func aSlowRunThatWaitsAtANamedPipeGoesToTheBackgroundAndItsFinalMessageComesAsMail()
    async throws
  {
    try await Self.proveASlowRunAtANamedPipeSettlesAsMail(label: "gate")
  }

  /// The same proof as
  /// ``aSlowRunThatWaitsAtANamedPipeGoesToTheBackgroundAndItsFinalMessageComesAsMail()``
  /// with a settle period of the real clock. The call of the root session
  /// waits for the period and then gives the pending envelope, while the run
  /// still waits at the pipe (task ^js730ph).
  @Test(.timeLimit(.minutes(1)))
  func aSlowRunAtANamedPipeGivesThePendingEnvelopeAfterTheRealSettlePeriod() async throws {
    try await Self.proveASlowRunAtANamedPipeSettlesAsMail(
      label: "gate-settle", inlineSettleGrace: Self.shortSettlePeriod, runClock: nil)
  }

  /// Makes a named pipe and a model whose slow run waits at it, and proves
  /// that the slow run settles as mail after a byte went into the pipe.
  ///
  /// - Parameters:
  ///   - label: The directory label of the calling test.
  ///   - inlineSettleGrace: The settle period of the context. Zero by default.
  ///   - runClock: The clock of the runs. A manual clock by default.
  /// - Throws: Whatever the fixtures or the write into the pipe throw.
  private static func proveASlowRunAtANamedPipeSettlesAsMail(
    label: String, inlineSettleGrace: TimeInterval = 0,
    runClock: (any RunClock)? = ManualRunClock()
  ) async throws {
    let gateName = "gate"
    let directory = try NamedPipe.makeDirectory(holding: gateName, label: "AgentsToolTests-\(label)")
    let pipe = directory.appendingPathComponent(gateName)
    // Sessions, not one script for every pass: the mail that the root session
    // gets later has the run prompt in it, and a script for every pass would
    // make that pass wait at the pipe a second time.
    let stubScript = ScriptedStubScript(sessions: [
      ScriptedStubScript.Session(
        promptContains: slowRunPrompt,
        passes: [[.gate(path: pipe.path), .textDelta(slowFinalText), .endPass]]),
      ScriptedStubScript.Session(
        promptContains: rootSlowPrompt,
        passes: [[startAgentCall(agent: slowAgent, prompt: slowRunPrompt), .endPass]]),
    ])
    let loader = StubModelLoader { _ in
      ScriptedLLMContainer(playbook: .sessions(stubScript))
    }
    try await proveASlowRunSettlesAsMail(
      label: label, loader: loader, inlineSettleGrace: inlineSettleGrace, runClock: runClock
    ) {
      try await NamedPipe.write("go", toPipeAt: pipe)
    }
  }

  /// Plays the root prompt of the slow run. The
  /// root session must get the pending envelope while the slow run waits.
  /// After `release` lets the run end, its final message must come as mail
  /// one time.
  ///
  /// - Parameters:
  ///   - label: The directory label of the calling test.
  ///   - loader: The model loader whose script plays the root session and the slow run.
  ///   - inlineSettleGrace: The settle period of the context. Zero by default.
  ///   - runClock: The clock of the runs. A manual clock by default, that the test never advances.
  ///   - release: Lets the waiting slow run end.
  /// - Throws: Whatever the fixtures or `release` throw.
  private static func proveASlowRunSettlesAsMail(
    label: String, loader: StubModelLoader, inlineSettleGrace: TimeInterval = 0,
    runClock: (any RunClock)? = ManualRunClock(), release: () async throws -> Void
  ) async throws {
    let context = try await makeContext(
      label: label, loader: loader, inlineSettleGrace: inlineSettleGrace, runClock: runClock)
    let surface = try await SurfaceCatalog.sessionSurface(context: context)
    let session = makeRootSession(surface: surface, context: context)

    _ = try await session.respond(to: rootSlowPrompt, maxTokens: nil)

    let output = try #require(agentsToolOutputs(in: await session.transcript).first)
    #expect(!output.contains(slowFinalText))
    #expect(output.contains(pendingMarker), "\(output)")
    try await release()
    // The open run counts as work. So the idle comes after the run ended.
    // It also comes after the answer of its mail.
    #expect(await session.awaitIdle())
    let mail = promptTexts(in: await session.transcript).filter {
      $0.contains(slowFinalText)
    }
    #expect(mail.count == 1)
    await session.close()
    await surface.shutdown()
  }

  // MARK: - The stop of the runs

  /// `stopAgentRuns()` cancels each run of the surface that is in
  /// operation.
  @Test
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

  /// The open record of a tool run of an agent run. Router of the agent
  /// run joined this run to an SDK call of the agent run.
  static let agentToolRunOpenRecord: SessionEvent = .toolInvocation(
    ToolInvocationRecord(
      tool: "shell", op: "execute command", correlationID: agentToolRunToken,
      sessionID: ULID.generate(), openedAt: Date(timeIntervalSince1970: 0)),
    toolCallID: "call-of-the-agent-run")

  /// The agent environment gives each session event of an agent run to the
  /// join table of the surface. The open record of a tool run of the agent
  /// run writes "no join" for that run. This holds while the agent run is
  /// in operation.
  /// So the terminal stream announces the run on its completion token.
  /// It does not wait for the end of the agent run.
  @Test
  func theOpenRecordOfAToolRunOfAnAgentRunWritesItsEntryWhileTheRunIsInOperation() async throws {
    let hold = ScriptedHold()
    let context = try await Self.makeContext(
      label: "observer", script: Self.startAgentScript(hold: hold))
    let surface = try await SurfaceCatalog.sessionSurface(context: context)
    let agents = try #require(surface.agents)
    let run = try await agents.runner.start(Self.slowAgent, prompt: Self.slowRunPrompt)
    let observer = try #require(agents.environment.runEventObserver)
    surface.runCallJoins.openProjection()

    observer(run, SessionOutput(origin: .system, event: Self.agentToolRunOpenRecord))

    #expect(run.state == .running)
    #expect(
      surface.runCallJoins.announceToolCallId(for: RunToken(Self.agentToolRunToken))
        == ToolCallId(rawValue: Self.agentToolRunToken))
    hold.release()
    await surface.shutdown()
  }

  /// `session/close` stops the agent runs of the session before the root
  /// session closes. When the close sweep of the root session finishes its
  /// event stream, the run is already cancelled.
  @Test
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

  // MARK: - The trace of the wake on agent mail (task ^3p03s3r)

  /// Runs one ACP prompt inside one capture. The `start agent` call of
  /// the prompt leaves the slow run in the background. The function ends
  /// the prompt and releases the run. Then it waits until the submission
  /// that the mail of the run starts ended.
  ///
  /// The settle period of the call runs on the real clock. The prompt ends
  /// when the period ends. The held run cannot end before the test
  /// releases it.
  ///
  /// - Returns: The spans of the run.
  /// - Throws: Whatever the fixture, the wire or the waits throw.
  static func runTheWakeOnAgentMail() async throws -> [FinishedInMemorySpan] {
    let hold = ScriptedHold()
    let cwd = makeResolvedDirectory(label: "AgentsToolTests-traced-wake-repo")
    try writeAgent(named: slowAgent, in: cwd)
    return try await TelemetryCapture.run(forbidding: []) { context in
      let fixture = try await ScriptedPromptFixture.make(
        script: startAgentScript(hold: hold), label: "AgentsToolTests-traced-wake",
        workingDirectory: cwd, tracer: context.tracer)
      _ = try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: rootSlowPrompt))
      await ScriptedPromptFixture.waitForPromptsFinished(fixture.harness.agent, fixture.sessionId)
      hold.release()
      _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
      await context.wait { capture in
        capture.spans.contains(where: RunMailWakeTrace.isRunMailSubmission)
      }
      _ = try await fixture.harness.connection.closeSession(
        CloseSessionRequest(sessionId: fixture.sessionId))
      await fixture.close()
      return context.spans
    }
  }

  /// The prompt ends while the agent run that it started waits in the
  /// background. The final message of the run starts an answer later, as
  /// mail to the root session. This answer is in the trace of the prompt.
  /// Its submission is no root span. Its parent is a span of the subtree
  /// of the prompt span. It links to the span that sent the mail.
  @Test
  func theWakeOnAgentMailAfterThePromptIsInTheTraceOfThePrompt() async throws {
    let spans = try await Self.runTheWakeOnAgentMail()

    try RunMailWakeTrace.expectTheWakeIsInTheTraceOfThePrompt(among: spans)
  }
}

import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import Testing

// MARK: - Tier 3: nested sub-agent sessions over the ACP wire, with real processes
//
// The prompt of the root session makes the root start an agent, and that agent starts a nested
// agent. A spawned `acp-agent-stub acp` plays the three sessions from a script, so no real model
// is needed. The client reads the wire of all sessions in one stream, in wire order. Only a
// spawned binary proves the order of the announcements, the refusal of the methods that a child
// does not permit, the cancel of one child, and the cold resume of a chain across two processes.

/// The nested run of a root session, a child and a grandchild, over the ACP wire.
@Suite(.timeLimit(.minutes(5)))
struct SubagentSessionsTests {
  // MARK: - Constants

  /// The id of the agent that the root session starts.
  private static let childAgent = "worker"

  /// The id of the agent that the child starts.
  private static let leafAgent = "leaf"

  /// The marker of the prompt of the root session.
  private static let rootPrompt = "ROOT-NEST-MARKER"

  /// The marker of the prompt of the child.
  private static let childPrompt = "CHILD-NEST-MARKER"

  /// The marker of the prompt of the grandchild.
  private static let leafPrompt = "LEAF-NEST-MARKER"

  /// The first text of the grandchild. The chain works when it is out.
  private static let leafText = "LEAF-NEST-TEXT"

  /// The text that a restored run plays when the second process starts it again.
  private static let redriveText = "NEST-REDRIVEN-TEXT"

  /// The start of the first message of a restored run.
  private static let restoredRunMessage = "The process stopped while you worked"

  /// The wire name of the method that a child refuses to prompt.
  private static let promptMethod = "session/prompt"

  /// The wire name of the method that a child refuses to close.
  private static let closeMethod = "session/close"

  /// The longest time that a read of the wire waits for the events that settle it.
  private static let readTimeout = Duration.seconds(90)

  /// The prefix of the labels of the folders of each test.
  private static let label = "SubagentSessionsTests"

  // MARK: - Fixtures

  /// The step of a script that plays the `start agent` call of the `agents` tool.
  ///
  /// - Parameters:
  ///   - agent: The id of the agent to start.
  ///   - prompt: The prompt that the new run gets.
  /// - Returns: The JSON text of the step.
  private static func startAgentStep(agent: String, prompt: String) -> String {
    """
    {"toolCall":{"name":"agents","arguments":
      {"op":"start agent","name":"\(agent)","prompt":"\(prompt)"}}}
    """
  }

  /// The script of a chain: the root starts the child, the child starts the grandchild, and the
  /// grandchild plays `leafSteps`.
  ///
  /// - Parameter leafSteps: The JSON text of the steps of the grandchild.
  /// - Returns: The JSON text of the script.
  private static func chainScript(leafSteps: String) -> String {
    """
    {"sessions":[
      {"match":{"promptContains":"\(leafPrompt)"},"passes":[[\(leafSteps)]]},
      {"match":{"promptContains":"\(childPrompt)"},
       "passes":[[\(startAgentStep(agent: leafAgent, prompt: leafPrompt))]]},
      {"match":{"promptContains":"\(rootPrompt)"},
       "passes":[[\(startAgentStep(agent: childAgent, prompt: childPrompt))]]}
    ]}
    """
  }

  /// The steps of a grandchild that plays its text and ends.
  private static let finishingLeafSteps = "{\"text\":\"\(leafText)\"}"

  /// The steps of a grandchild that plays its text and holds at a gate that never opens, until a
  /// stop of its run ends the pass.
  ///
  /// - Parameter label: The label of the folder of the gate.
  /// - Returns: The JSON text of the steps.
  private static func holdingLeafSteps(label: String) -> String {
    let gate = NestedAgentFixture.gateFile(label: label)
    return "{\"text\":\"\(leafText)\"},{\"gate\":\"\(gate.path)\"}"
  }

  /// A project folder with the agents of the chain, and a configuration home.
  private struct Folders {
    /// The project folder.
    let workspace: URL

    /// The configuration home.
    let configHome: URL

    /// Makes the folders. The child has the `agents` tool, so it can start the grandchild.
    ///
    /// - Parameter label: The label of the folders.
    /// - Throws: The directory-creation or write error.
    init(label: String) throws {
      workspace = makeResolvedDirectory(label: "\(label)-repo")
      configHome = makeResolvedDirectory(label: "\(label)-config")
      try NestedAgentFixture.writeAgent(
        named: childAgent, tools: NestedAgentFixture.agentsToolName, in: workspace)
      try NestedAgentFixture.writeAgent(named: leafAgent, in: workspace)
    }
  }

  /// Spawns the agent over a script of the chain, and sends the prompt of the root.
  ///
  /// - Parameters:
  ///   - folders: The folders of the test.
  ///   - leafSteps: The JSON text of the steps of the grandchild.
  ///   - label: The label of the script file.
  /// - Returns: The running session.
  /// - Throws: The spawn or request error.
  private static func startChain(
    in folders: Folders, leafSteps: String, label: String
  ) async throws -> NestedRootSession {
    try await NestedRootSession.start(
      workspace: folders.workspace,
      environment: NestedAgentFixture.environment(
        script: chainScript(leafSteps: leafSteps), configHome: folders.configHome, label: label),
      prompt: rootPrompt)
  }

  /// Whether the grandchild plays its first text in the trace.
  ///
  /// - Parameters:
  ///   - trace: The trace so far.
  ///   - root: The root session.
  /// - Returns: `true` when the root announced a child, the child announced a grandchild, and the
  ///   grandchild sent its text.
  private static func leafIsWorking(_ trace: [WireTraceEvent], root: SessionId) -> Bool {
    guard let chain = trace.chain(of: root) else {
      return false
    }
    return trace.contains { $0.isAgentText(containing: leafText, on: chain.leaf) }
  }

  /// A running chain of a root, a child and a grandchild, with the wire read so far.
  private struct NestedChain {
    /// The session of the root, still connected.
    let session: NestedRootSession

    /// The wire of the run, in wire order.
    let trace: [WireTraceEvent]

    /// The child of the root.
    let child: SessionId

    /// The child of the child.
    let leaf: SessionId

    /// Makes the chain from a trace that names the child and the grandchild.
    ///
    /// - Parameters:
    ///   - session: The session of the root.
    ///   - trace: The wire read so far.
    /// - Throws: A failed requirement when the wire names no child or no grandchild.
    init(session: NestedRootSession, trace: [WireTraceEvent]) throws {
      let names = try #require(trace.chain(of: session.root))
      self.session = session
      self.trace = trace
      child = names.child
      leaf = names.leaf
    }
  }

  /// Runs a chain whose grandchild ends at once, and reads the wire until the root, the child and
  /// the grandchild are idle.
  ///
  /// - Parameter label: The label of the folders.
  /// - Returns: The chain, with its trace.
  /// - Throws: The spawn or request error, or a failed requirement when the wire names no child
  ///   or no grandchild.
  private static func runFinishedChain(label: String) async throws -> NestedChain {
    let session = try await startChain(
      in: Folders(label: label), leafSteps: finishingLeafSteps, label: label)
    let root = session.root
    let trace = await session.subscription.readLiveTrace(
      until: { trace in
        guard let chain = trace.chain(of: root) else {
          return false
        }
        return [chain.leaf, chain.child, root].allSatisfy { id in
          trace.contains { $0.isIdle(of: id) }
        }
      }, timeout: readTimeout)
    return try NestedChain(session: session, trace: trace)
  }

  /// Ends the agent with the orderly shutdown of the process (the end of its input), and closes
  /// the client side.
  ///
  /// - Parameter session: The session to end.
  /// - Returns: How the agent ended.
  /// - Throws: The close error.
  @discardableResult
  private static func quit(_ session: NestedRootSession) async throws -> SpawnedAgentExit {
    let exit = try await session.agent.closeStandardInputAndWait()
    await session.closeClientSide()
    return exit
  }

  // MARK: - The order of the wire

  /// The root announces the child, the child announces the grandchild, each session sends its
  /// events under its own id after its announcement, and the sessions go idle from the grandchild
  /// up to the root.
  @Test
  func theChainIsAnnouncedParentFirstAndGoesIdleFromTheLeafUp() async throws {
    let chain = try await Self.runFinishedChain(label: "\(Self.label)-order")
    let trace = chain.trace
    let root = chain.session.root

    let childAnnounced = try #require(
      trace.firstIndex { $0.isAnnouncement(of: chain.child, on: root) })
    let leafAnnounced = try #require(
      trace.firstIndex { $0.isAnnouncement(of: chain.leaf, on: chain.child) })
    let childEvent = try #require(trace.firstIndex { $0.isToolCall(on: chain.child) })
    let leafEvent = try #require(
      trace.firstIndex { $0.isAgentText(containing: Self.leafText, on: chain.leaf) })
    let leafIdle = try #require(trace.firstIndex { $0.isIdle(of: chain.leaf) })
    let childIdle = try #require(trace.firstIndex { $0.isIdle(of: chain.child) })
    let rootIdle = try #require(trace.firstIndex { $0.isIdle(of: root) })

    #expect(childAnnounced < leafAnnounced)
    #expect(childAnnounced < childEvent)
    #expect(leafAnnounced < leafEvent)
    #expect(leafIdle < childIdle)
    #expect(childIdle < rootIdle)
    try await Self.quit(chain.session)
  }

  /// The whole trace of a live nested run follows the rules of the validator for sub-agent
  /// sessions.
  @Test
  func theWireOfTheChainFollowsTheRulesOfTheValidator() async throws {
    let chain = try await Self.runFinishedChain(label: "\(Self.label)-rules")

    let violations = SubagentWireTraceValidator().validate(chain.trace)

    #expect(violations == [])
    try await Self.quit(chain.session)
  }

  // MARK: - The list of sessions

  /// `session/list` shows the root session only. The child and the grandchild have recordings,
  /// and the list leaves them out.
  @Test
  func sessionListShowsOnlyTheRootSession() async throws {
    let chain = try await Self.runFinishedChain(label: "\(Self.label)-list")

    let listed = try await chain.session.connection.listSessions(
      ListSessionsRequest(cwd: AbsolutePath(rawValue: chain.session.workspace.path)))

    #expect(listed.sessions.map(\.sessionId) == [chain.session.root])
    try await Self.quit(chain.session)
  }

  // MARK: - A working chain

  /// Runs a chain whose grandchild holds at a gate, and reads the wire until the grandchild
  /// plays its first text.
  ///
  /// - Parameters:
  ///   - folders: The folders of the test.
  ///   - label: The label of the script and of the gate.
  /// - Returns: The chain, with its trace.
  /// - Throws: The spawn or request error, or a failed requirement when the wire names no child
  ///   or no grandchild.
  private static func runWorkingChain(in folders: Folders, label: String) async throws
    -> NestedChain
  {
    let session = try await startChain(
      in: folders, leafSteps: holdingLeafSteps(label: label), label: label)
    let root = session.root
    let trace = await session.subscription.readLiveTrace(
      until: { leafIsWorking($0, root: root) }, timeout: readTimeout)
    return try NestedChain(session: session, trace: trace)
  }

  // MARK: - The methods of a child

  /// A child session permits `session/cancel` only. A `session/prompt` and a `session/close` on
  /// its id are refused.
  @Test
  func aChildSessionRefusesPromptAndClose() async throws {
    let chain = try await Self.runWorkingChain(
      in: Folders(label: "\(Self.label)-refuse"), label: "\(Self.label)-refuse")
    let connection = chain.session.connection
    let prompt = AgentClientHarness.makePromptRequest(sessionId: chain.child, text: "Hello.")

    let promptError = await requestErrorThrown { _ = try await connection.prompt(prompt) }
    let closeError = await requestErrorThrown {
      _ = try await connection.closeSession(CloseSessionRequest(sessionId: chain.child))
    }

    #expect(isMethodRefusal(promptError, of: Self.promptMethod, on: chain.child))
    #expect(isMethodRefusal(closeError, of: Self.closeMethod, on: chain.child))
    try await Self.quit(chain.session)
  }

  // MARK: - The cancel of a child

  /// `session/cancel` on the id of the child ends the child and the grandchild that it waits for,
  /// each with `idle` and the stop reason `cancelled`. The root goes on and ends its own turn.
  @Test
  func cancelOfTheChildEndsTheChildAndLeavesTheRoot() async throws {
    let chain = try await Self.runWorkingChain(
      in: Folders(label: "\(Self.label)-cancel"), label: "\(Self.label)-cancel")
    let root = chain.session.root
    let cancelledAt = chain.trace.count

    try await chain.session.connection.sessionCancel(
      CancelSessionNotification(sessionId: chain.child))
    let trace = await chain.session.subscription.readLiveTrace(
      extending: chain.trace,
      until: { trace in
        let after = trace.dropFirst(cancelledAt)
        return after.contains { $0.isIdle(of: root) }
          && after.contains { $0.isIdle(of: chain.child, stopReason: .cancelled) }
          && after.contains { $0.isIdle(of: chain.leaf, stopReason: .cancelled) }
      }, timeout: Self.readTimeout)
    let after = trace.dropFirst(cancelledAt)

    #expect(after.contains { $0.isIdle(of: chain.child, stopReason: .cancelled) })
    #expect(after.contains { $0.isIdle(of: chain.leaf, stopReason: .cancelled) })
    #expect(after.contains { $0.isIdle(of: root) })
    #expect(!after.contains { $0.isIdle(of: root, stopReason: .cancelled) })
    try await Self.quit(chain.session)
  }

  // MARK: - The cold resume

  /// What the first process recorded.
  private struct Recording {
    /// The folders of the test.
    let folders: Folders

    /// The root session.
    let root: SessionId

    /// The child of the root.
    let child: SessionId

    /// The child of the child.
    let leaf: SessionId

    /// The id of the `agents` call that the root started in the first process.
    let call: ToolCallId
  }

  /// Runs the first process: the chain works, and the grandchild holds. Then the process quits
  /// in an orderly way. The quit pauses the open `agents` calls, and cancels nothing.
  ///
  /// - Returns: What the process recorded.
  /// - Throws: The spawn, request or wait error.
  private static func recordQuitChain() async throws -> Recording {
    let label = "\(Self.label)-quit"
    let folders = try Folders(label: label)
    let chain = try await runWorkingChain(in: folders, label: label)
    let root = chain.session.root
    let call = try #require(chain.trace.firstToolCallId(on: root))
    try await quit(chain.session)
    return Recording(
      folders: folders, root: root, child: chain.child, leaf: chain.leaf, call: call)
  }

  /// The script of the second process: each restored run answers its first message.
  private static var restoredScript: String {
    """
    {"sessions":[
      {"match":{"promptContains":"\(restoredRunMessage)"},
       "passes":[[{"text":"\(redriveText)"}]]}
    ]}
    """
  }

  /// Resumes the root in a second process with the replay from the start, and reads the wire until
  /// the end of the restored chain completes the original `agents` call of the root.
  ///
  /// - Parameter recording: What the first process recorded.
  /// - Returns: The trace of the wire, from the request.
  /// - Throws: The spawn, request or wait error.
  private static func resume(_ recording: Recording) async throws -> [WireTraceEvent] {
    try await NestedAgentFixture.resumeTrace(
      of: recording.root, workspace: recording.folders.workspace,
      configHome: recording.folders.configHome, script: restoredScript,
      label: "\(Self.label)-resume", replayFrom: .start(ReplayFromStart()),
      settledBy: { $0.isCompletedCall(recording.call, on: recording.root) },
      timeout: readTimeout)
  }

  /// The wire of a cold resume of a chain that the first process left running. The history of the
  /// chain goes out before the response, the parent before the child. The current snapshots come
  /// after the response, and the restored runs start after them. The trace follows the rules of
  /// the validator.
  @Test
  func aColdResumeReplaysTheChainParentFirstAndRestoresTheRunsAfterTheResponse() async throws {
    let recording = try await Self.recordQuitChain()

    let trace = try await Self.resume(recording)
    let response = try #require(trace.firstIndex { $0.isResumeResponse })
    let childAnnounced = try #require(
      trace.firstIndex { $0.isAnnouncement(of: recording.child, on: recording.root) })
    let leafAnnounced = try #require(
      trace.firstIndex { $0.isAnnouncement(of: recording.leaf, on: recording.child) })
    let leafHistory = try #require(
      trace.firstIndex { $0.isAgentText(containing: Self.leafText, on: recording.leaf) })
    let leafSnapshot = trace.indices.first {
      $0 > response && trace[$0].isAnnouncement(of: recording.leaf, on: recording.child)
    }
    let redrive = try #require(
      trace.firstIndex { $0.isAgentText(containing: Self.redriveText, on: recording.leaf) })

    #expect(childAnnounced < leafAnnounced)
    #expect(leafAnnounced < response)
    #expect(leafHistory < response)
    #expect(leafSnapshot != nil)
    #expect(response < redrive)
    #expect(SubagentWireTraceValidator().validate(trace) == [])
  }
}

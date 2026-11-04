// `SpawnedAgentPromptDrive` — one prompt over a spawned `acp-agent acp`
// with an environment of its own, and then one chosen end of the agent.
//
// The telemetry suites each spawn the agent over the stub model, run
// `initialize`, `session/new` and one prompt, and then end the agent on a
// path they choose. The scripted elicitation suite does the same and answers
// the question of the agent while the prompt runs. This type holds that
// drive, so the suites do not keep copies of it.

import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient

/// What one prompt over a spawned `acp-agent-stub acp` gave back.
struct SpawnedAgentPromptDrive {
  /// The response to `initialize`.
  let initialized: InitializeResponse

  /// What the update stream of the session held to the idle of the prompt.
  let read: PromptUpdateRead

  /// The question that the agent asked while the prompt ran, or `nil` for
  /// a drive with no question hook.
  let question: CreateElicitationRequest?

  /// The stop reason of the prompt, or `nil` when the prompt did not end.
  var stopReason: StopReason? { read.stopReason }

  /// The raw bytes the agent wrote to its stdout.
  let standardOutput: Data

  /// How the agent ended.
  let exit: SpawnedAgentExit

  /// Spawns `acp-agent-stub acp` over the stub model, runs `initialize`,
  /// `session/new` and one prompt, and then ends the agent with `ending`.
  ///
  /// The child starts from the environment of this process, and gets each
  /// pair of `environment` and its own configuration home on top.
  ///
  /// - Parameters:
  ///   - label: The directory label, so a leftover directory tells where it
  ///     came from.
  ///   - environment: The extra environment pairs for the agent.
  ///   - promptText: The text of the one prompt.
  ///   - answeringQuestionWith: The elicitation hook, or `nil` (the
  ///     default) for a prompt that asks no question. The prompt does not
  ///     return before the agent has its answer, so the hook runs beside
  ///     the prompt: it waits for the question, resolves it, and gives the
  ///     question back.
  ///   - ending: The end request and the wait for the end.
  /// - Returns: The drive.
  /// - Throws: The spawn, request or wait error.
  static func run(
    label: String,
    environment: [String: String],
    promptText: String,
    answeringQuestionWith answerQuestion: ((SessionModel) async -> CreateElicitationRequest)? = nil,
    ending: (SpawnedACPAgent) async throws -> SpawnedAgentExit
  ) async throws -> SpawnedAgentPromptDrive {
    let workspace = makeResolvedDirectory(label: "\(label)-repo")
    let configHome = makeResolvedDirectory(label: "\(label)-config")
    let childEnvironment =
      environment
      .merging([TierThreeFixture.configHomeVariable: configHome.path]) { _, home in home }
    let agent = try SpawnedACPAgent.start(workspace: workspace, environment: childEnvironment)
    let tap = InboundTapTransport(wrapping: agent.transport)
    let model = await ConnectionModel()
    let connection = await model.connect(over: tap)

    let initialized = try await model.initialize(AgentClientHarness.makeInitializeRequest())
    let session = try await model.newSession(
      NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
    let sessionId = session.sessionId
    // Subscribe before the prompt, so the stream holds each update of
    // the prompt in order.
    let updates = connection.subscribe(to: sessionId).updates
    let reader = Task { await PromptUpdateRead.collect(from: updates) }
    let prompt = Task {
      try await connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: sessionId, text: promptText))
    }
    let question = await answerQuestion?(session)
    _ = try await prompt.value
    let read = await reader.value

    let exit = try await ending(agent)
    await connection.close()
    return SpawnedAgentPromptDrive(
      initialized: initialized, read: read, question: question,
      standardOutput: tap.recordedBytes, exit: exit)
  }
}

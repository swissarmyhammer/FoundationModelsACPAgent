// `SpawnedAgentPromptDrive` — one prompt over a spawned `acp-agent acp`
// with an environment of its own, and then one chosen end of the agent.
//
// The telemetry suite and the suite of the limit of a child spawn the agent
// over the stub model, run `initialize`, `session/new` and one prompt, and
// then end the agent on a path they choose. The suite of the limit answers
// the question of the agent while the prompt runs. This type holds that
// drive, so the suites do not keep copies of it.

import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient

/// What one prompt over a spawned `acp-agent-stub acp` gave back.
struct SpawnedAgentPromptDrive {
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
  /// The drive fails at once and with a reason, and never waits without an
  /// end: the agent is killed at `limit` (see ``ChildDeadline``), the hook
  /// that waits for a question ends when the turn ends, and each failure
  /// holds the stderr of the agent.
  ///
  /// - Parameters:
  ///   - label: The directory label, so a leftover directory tells where it
  ///     came from.
  ///   - environment: The extra environment pairs for the agent.
  ///   - promptText: The text of the one prompt.
  ///   - limit: The longest time the agent may run.
  ///   - answeringQuestionWith: The elicitation hook, or `nil` (the
  ///     default) for a prompt that asks no question. The prompt does not
  ///     return before the agent has its answer, so the hook runs beside
  ///     the prompt: it waits for the question, resolves it, and gives the
  ///     question back.
  ///   - ending: The end request and the wait for the end.
  /// - Returns: The drive.
  /// - Throws: ``ChildDeadlineExceeded`` when the agent passed `limit`,
  ///   ``PromptEndedWithoutQuestion`` (inside ``SpawnedAgentFailure``) when the
  ///   turn ended before the hook had a question, and else the error of the step that failed, with the
  ///   stderr of the agent (``SpawnedAgentFailure``).
  static func run(
    label: String,
    environment: [String: String],
    promptText: String,
    limit: Duration = ChildDeadline.standardLimit,
    answeringQuestionWith answerQuestion:
      (@Sendable (SessionModel) async throws -> CreateElicitationRequest)? = nil,
    ending: (SpawnedACPAgent) async throws -> SpawnedAgentExit
  ) async throws -> SpawnedAgentPromptDrive {
    let workspace = makeResolvedDirectory(label: "\(label)-repo")
    let configHome = makeResolvedDirectory(label: "\(label)-config")
    let childEnvironment =
      environment
      .merging([TierThreeFixture.configHomeVariable: configHome.path]) { _, home in home }
    let agent = try SpawnedACPAgent.start(
      workspace: workspace, environment: childEnvironment, limit: limit)
    do {
      return try await drive(
        agent, workspace: workspace, promptText: promptText,
        answeringQuestionWith: answerQuestion, ending: ending)
    } catch {
      agent.abandon()
      throw agent.report(error)
    }
  }

  /// The steps of ``run(label:environment:promptText:limit:answeringQuestionWith:ending:)``
  /// after the spawn.
  ///
  /// - Parameters:
  ///   - agent: The running agent.
  ///   - workspace: The working directory of the agent.
  ///   - promptText: The text of the one prompt.
  ///   - answerQuestion: The elicitation hook, or `nil`.
  ///   - ending: The end request and the wait for the end.
  /// - Returns: The drive.
  /// - Throws: The error of the step that failed.
  private static func drive(
    _ agent: SpawnedACPAgent,
    workspace: URL,
    promptText: String,
    answeringQuestionWith answerQuestion:
      (@Sendable (SessionModel) async throws -> CreateElicitationRequest)?,
    ending: (SpawnedACPAgent) async throws -> SpawnedAgentExit
  ) async throws -> SpawnedAgentPromptDrive {
    let tap = InboundTapTransport(wrapping: agent.transport)
    let model = await ConnectionModel()
    let connection = await model.connect(over: tap)

    _ = try await model.initialize(AgentClientHarness.makeInitializeRequest())
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
    var question: CreateElicitationRequest?
    if let answerQuestion {
      question = try await answering(
        session, with: answerQuestion, whilePrompting: prompt, turn: reader)
    }
    _ = try await prompt.value
    let read = await reader.value

    let exit = try await ending(agent)
    await connection.close()
    return SpawnedAgentPromptDrive(
      read: read, question: question,
      standardOutput: tap.recordedBytes, exit: exit)
  }

  /// Runs the elicitation hook beside the prompt, and stops the hook when the
  /// prompt fails or the turn ends first.
  ///
  /// The response of `session/prompt` comes when the agent accepts the prompt,
  /// so the end of the turn is the idle update that the reader holds.
  ///
  /// - Parameters:
  ///   - session: The session model of the client.
  ///   - hook: The elicitation hook.
  ///   - prompt: The prompt request that is in flight.
  ///   - turn: The read of the updates of the session, which ends with the
  ///     idle update, or with the close of the connection.
  /// - Returns: The question that the hook gave back.
  /// - Throws: The error of the prompt when it failed first,
  ///   ``PromptEndedWithoutQuestion`` when the turn ended with no question,
  ///   and else the error of the hook.
  private static func answering(
    _ session: SessionModel,
    with hook: @escaping @Sendable (SessionModel) async throws -> CreateElicitationRequest,
    whilePrompting prompt: Task<PromptResponse, any Error>,
    turn: Task<PromptUpdateRead, Never>
  ) async throws -> CreateElicitationRequest {
    let asking = Task { try await hook(session) }
    let promptFailure = WatchedValue<(any Error)?>(nil)
    let turnEnded = WatchedValue(false)
    let watchingPrompt = Task {
      if case .failure(let error) = await prompt.result {
        promptFailure.update { $0 = error }
        asking.cancel()
      }
    }
    let watchingTurn = Task {
      _ = await turn.value
      turnEnded.update { $0 = true }
      asking.cancel()
    }
    defer {
      watchingPrompt.cancel()
      watchingTurn.cancel()
    }
    do {
      return try await asking.value
    } catch {
      if let promptError = promptFailure.value {
        throw promptError
      }
      if turnEnded.value {
        throw PromptEndedWithoutQuestion()
      }
      throw error
    }
  }
}

/// A turn that ended while the hook of the drive still waited for a
/// question: the agent asked none.
struct PromptEndedWithoutQuestion: Error, CustomStringConvertible {
  /// What happened.
  var description: String {
    "the turn ended before the agent asked a question"
  }
}

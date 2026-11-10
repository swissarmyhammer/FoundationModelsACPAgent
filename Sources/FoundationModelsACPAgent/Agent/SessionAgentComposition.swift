import Foundation
import FoundationModelsACP
import FoundationModelsAgents
import FoundationModelsRouter

/// The agent part of one session composition: the agent, the rendered text
/// of its instructions, and the role of the `AGENT.md` of the working
/// directory.
struct SessionAgentPrompt {
  /// The agent of the session, or `nil` when the session has no agent
  /// catalog.
  let agent: ComposedSessionAgent?

  /// The rendered instructions of the agent (its body, then the bodies of
  /// its `skills:` preload), or `nil` for the builtin floor.
  let text: String?

  /// The definition of the agent, or `nil` for the builtin floor. Its
  /// `tools:` and `disallowedTools:` keys filter the surface of the session
  /// (``SessionSurface/applying(agent:)``).
  let definition: AgentDefinition?

  /// The role of the `AGENT.md` of the working directory in the
  /// instructions of the session.
  let workingDirectoryAgent: InstructionsAssembler.WorkingDirectoryAgent

  /// The prompt of a session with no agent catalog: the builtin floor.
  static let builtin = SessionAgentPrompt(
    agent: nil, text: nil, definition: nil, workingDirectoryAgent: .alias)
}

extension RoutedACPAgent {
  /// Resolves the agent of one session and renders its instructions
  /// (ACPA-1, ``SessionAgentResolution``).
  ///
  /// A new session resolves its agent from the `agent` option, the
  /// `AGENT.md` of the working directory, and the default agent. A resumed
  /// session reads the agent that ``SessionAgentStore`` recorded; a session
  /// with no record resolves as a new session with no option.
  ///
  /// - Parameters:
  ///   - runner: The agent runner of the session surface, or `nil` when the
  ///     session has no agent catalog.
  ///   - requested: The value of the `agent` option, or `nil` for none.
  ///   - resumedSessionId: The id of the resumed session, or `nil` for a new
  ///     session.
  ///   - workingDirectory: The working directory of the session.
  ///   - transcriptRoot: The recording root of the session.
  /// - Returns: The agent and its instructions.
  /// - Throws: `RequestError.invalidConfigOptionValue(id:)` for an unknown
  ///   agent, or the render failure of the agent.
  func composeSessionAgent(
    runner: AgentRunner?,
    requested: String?,
    resuming resumedSessionId: SessionId?,
    workingDirectory: URL,
    transcriptRoot: URL
  ) async throws -> SessionAgentPrompt {
    guard let runner else {
      // With no catalog, only `default` (here the builtin floor) is known.
      guard requested == nil || requested == ConfigOptions.defaultAgentValue else {
        throw RequestError.invalidConfigOptionValue(id: ConfigOptions.agentOptionId)
      }
      return .builtin
    }
    let catalog = runner.catalog()
    let layerRoots = settingsFolders.stack(for: .agents, workingDirectory: workingDirectory)
      .layers.map(\.root)
    let recorded = resumedSessionId.flatMap { id in
      SessionAgentStore.choice(of: id, in: transcriptRoot)
    }
    let resolved =
      try recorded.map { choice in
        SessionAgentResolution.restore(
          choice, catalog: catalog, workingDirectory: workingDirectory, layerRoots: layerRoots)
      }
      ?? SessionAgentResolution.resolve(
        requested: requested, catalog: catalog, workingDirectory: workingDirectory,
        layerRoots: layerRoots)
    return SessionAgentPrompt(
      agent: ComposedSessionAgent(
        choice: resolved.choice,
        option: ConfigOptions.AgentOption(catalog: catalog, agent: resolved),
        slot: startSlot(of: resolved.definition)),
      text: try await renderedInstructions(of: resolved.definition, runner: runner),
      definition: resolved.definition,
      workingDirectoryAgent: resolved.workingDirectoryAgent)
  }

  /// The start slot of a session for the `model:` key of its agent
  /// (``ConfigOptions/slot(forAgentModel:)``). A value that names no slot
  /// gives a warning in the log.
  ///
  /// - Parameter definition: The agent, or `nil` for the builtin floor.
  /// - Returns: The slot.
  private func startSlot(of definition: AgentDefinition?) -> ModelSlot {
    let start = ConfigOptions.slot(forAgentModel: definition?.model)
    if let warning = start.warning {
      ACPAgentTelemetry.logger(.session).warning("\(warning)")
    }
    return start.slot
  }

  /// The rendered instructions of the session agent. Each skill of its
  /// `skills:` preload that cannot load gives a warning in the log.
  ///
  /// - Parameters:
  ///   - definition: The agent, or `nil` for the builtin floor.
  ///   - runner: The agent runner that renders the agent.
  /// - Returns: The text, or `nil` for the builtin floor.
  /// - Throws: The render failure of the agent.
  private func renderedInstructions(of definition: AgentDefinition?, runner: AgentRunner)
    async throws -> String?
  {
    guard let definition else {
      return nil
    }
    let instructions = try await runner.sessionAgentInstructions(for: definition)
    for diagnostic in instructions.diagnostics {
      ACPAgentTelemetry.logger(.session).warning(
        "The session agent has a skill that it cannot preload: \(diagnostic)")
    }
    return instructions.text
  }

  /// Records the agent of a new session with its recording, so a resume
  /// composes the same agent. A failure is logged and does not fail the
  /// session.
  ///
  /// - Parameters:
  ///   - composition: The composition of the new session.
  ///   - sessionId: The id of the new session.
  func recordSessionAgent(of composition: SessionComposition, for sessionId: SessionId) {
    guard let choice = composition.agent?.choice else {
      return
    }
    do {
      try SessionAgentStore.record(choice, for: sessionId, in: composition.transcriptRoot)
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The agent of the new session was not recorded. A resume resolves the agent again.",
        metadata: ACPAgentTelemetry.sessionMetadata(sessionId))
    }
  }
}

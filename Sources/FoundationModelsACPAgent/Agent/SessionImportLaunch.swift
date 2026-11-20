import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

// The target of an import (D209 (h)).
//
// `RouterSessionDirectory.importSession(_:transcript:)` writes the recording of an imported
// session through the launcher of the agent (`AgentSessionLauncher.importTarget(for:)`). The
// launcher gives the model handle and the configuration that a new root session of the agent
// in the folder of the import gets from `session/new`. No session is live after the import: a
// later `session/resume` restores the recording with the normal restore of the agent.

extension RoutedACPAgent {
  /// The work of ``AgentSessionLauncher/importTarget(for:)``: the model handle and the
  /// configuration of a new root session in the folder of `request`.
  ///
  /// The agent composes the session as `session/new` does
  /// (``composeSession(from:workingDirectory:additionalRoots:clientMCPServers:userPresence:requestedAgent:resuming:)``),
  /// with no additional directory, no MCP server of a client and the user presence of a user.
  /// The agent of `request` resolves as for a start: with no agent id, the `AGENT.md` of the
  /// folder, else the default agent. The model handle is the handle of the start slot of that
  /// agent, and the configuration is the configuration of a new session over it
  /// (`RoutedLLM.budgetedConfiguration`):
  /// the instructions, the recording root of the folder, the compaction budget and the agent.
  /// No session runs on the surface, so the agent then shuts the surface down.
  ///
  /// Before the composition, the agent records the folder in the project store of the home, as
  /// for a fork, so a failed save makes no import.
  ///
  /// - Parameter request: The import request of the session directory.
  /// - Returns: The model handle and the configuration of the import.
  /// - Throws: `SessionDirectoryError.notADirectory(_:)` when the folder of the request is not
  ///   a folder, the error of the project file save, or the error of the composition.
  func importTarget(for request: SessionImportRequest) async throws -> SessionImportTarget {
    let workingDirectory = request.workingDirectory
    guard PathKind.of(workingDirectory) == .directory else {
      throw SessionDirectoryError.notADirectory(workingDirectory)
    }
    let placement = SessionPlacement(
      workingDirectory: workingDirectory, additionalRoots: [], userPresence: .interactive,
      clientMCPServers: [])
    try registerProject(of: placement)
    let composition = try await composeSession(
      from: loadSessionContext(workingDirectory: workingDirectory),
      workingDirectory: workingDirectory, additionalRoots: placement.additionalRoots,
      clientMCPServers: placement.clientMCPServers, userPresence: placement.userPresence,
      requestedAgent: request.agentID)
    composition.surface.shellOutput?.finish()
    await composition.surface.shutdown()
    let model = ConfigOptions.handle(for: composition.startSlot, of: residentProfile)
    return SessionImportTarget(
      model: model,
      configuration: model.budgetedConfiguration(
        instructions: composition.instructions,
        workingDirectory: workingDirectory,
        recordingRoot: composition.transcriptRoot,
        tools: composition.surface.tools,
        compaction: composition.configuration.compaction,
        repetition: composition.configuration.repetition,
        inlineSettleGrace: composition.surface.inlineSettleGrace,
        userPresence: placement.userPresence,
        mailOnlyAnswerLimit: mailOnlyAnswerLimit,
        hookLineage: HookLineage(workingDirectory: workingDirectory, origin: .new),
        agentID: composition.agent?.choice.id,
        agentName: composition.agent?.name,
        transcriptReader: transcriptReader))
  }
}

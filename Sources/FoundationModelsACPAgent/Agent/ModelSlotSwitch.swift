import FoundationModelsACP
import FoundationModelsRouter
import Logging

/// The model slot switch of a session. The ACP session is backed by one
/// Router session for its whole life, so the switch keeps the id: it suspends
/// the Router session and restores it onto the handle of the new slot.
/// The restore keeps the id, the recording folder and the lineage. It adds
/// one `modelChanged` event to the transcript of each moved session.
extension RoutedACPAgent {
  /// Switches the generation slot of a session.
  ///
  /// A session with no open prompt switches at once. A prompt that is open
  /// ends on the Router session that took it, so a switch during a prompt
  /// waits: the switch applies when the last open prompt ends
  /// (``applyPendingModelSlot(of:)``). The folder of the session has one
  /// writer at a time, and the restore reads the transcript from disk.
  ///
  /// - Parameters:
  ///   - slot: The selected slot. A set to the current slot changes
  ///     nothing.
  ///   - sessionId: The session to switch.
  /// - Throws: `RequestError.internalError` when the restore failed. The
  ///   session then keeps its slot.
  func applyModelSlot(_ slot: ModelSlot, to sessionId: SessionId) async throws {
    await awaitSlotSwitch(of: sessionId)
    guard let entry = sessions[sessionId], !entry.isClosed,
      slot != (entry.pendingSlot ?? entry.selectedSlot)
    else {
      return
    }
    guard entry.openPrompts.isEmpty else {
      sessions[sessionId]?.pendingSlot = slot
      return
    }
    try await switchSession(sessionId, to: slot)
  }

  /// Applies the switch that a client asked for while a prompt was open.
  /// The end of the last open prompt calls it. A failed switch is logged:
  /// no client request is open to carry the error, and the reconcile of the
  /// config options then shows the slot that the session keeps.
  ///
  /// - Parameter sessionId: The session whose last prompt ended.
  func applyPendingModelSlot(of sessionId: SessionId) async {
    guard let entry = sessions[sessionId], !entry.isClosed, let pending = entry.pendingSlot else {
      return
    }
    sessions[sessionId]?.pendingSlot = nil
    guard pending != entry.selectedSlot else {
      return
    }
    do {
      try await switchSession(sessionId, to: pending)
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "A model slot switch that waited for a prompt failed. The session keeps its slot.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
    }
  }

  /// Waits until the model slot switch of the session ended. It returns at
  /// once when the session is not in a switch. A caller reads the Router
  /// session of the entry after this call.
  ///
  /// - Parameter sessionId: The session.
  func awaitSlotSwitch(of sessionId: SessionId) async {
    while let switching = sessions[sessionId]?.slotSwitch {
      _ = await switching.result
    }
  }

  /// Runs the switch in a task that the entry keeps, so a prompt, a close
  /// and a second switch wait for it (``awaitSlotSwitch(of:)``). The task
  /// clears the entry itself, so a waiter that resumes finds it clear.
  ///
  /// - Parameters:
  ///   - sessionId: The session to switch.
  ///   - slot: The slot to move the session to.
  /// - Throws: Whatever ``moveSession(_:to:)`` throws.
  private func switchSession(_ sessionId: SessionId, to slot: ModelSlot) async throws {
    let switching = Task {
      defer { sessions[sessionId]?.slotSwitch = nil }
      try await moveSession(sessionId, to: slot)
    }
    sessions[sessionId]?.slotSwitch = switching
    try await switching.value
  }

  /// Suspends the Router session of the entry and restores it onto `slot`
  /// with the same id. The suspend writes no ended marker, so the restore
  /// finds the session. The close that follows the suspend takes the session
  /// off the live list of the directory, and it comes before the restore,
  /// because it removes the entry of the id.
  ///
  /// When the restore fails, the session is restored onto its old slot, so
  /// the client keeps a session that works.
  ///
  /// - Parameters:
  ///   - sessionId: The session to move.
  ///   - slot: The slot to move the session to.
  /// - Throws: `RequestError.internalError` when the restore failed.
  private func moveSession(_ sessionId: SessionId, to slot: ModelSlot) async throws {
    guard let entry = sessions[sessionId] else {
      return
    }
    let replaced = entry.session
    replaced.suspend()
    await replaced.close()
    do {
      let restored = try await restoreSession(of: entry, onto: slot)
      await install(restored, in: sessionId, slot: slot, replacing: replaced.id)
    } catch {
      ACPAgentTelemetry.logger(.session).error(
        "The model slot switch could not restore the session. The session returns to its slot.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
      await returnToSlot(of: entry, in: sessionId)
      throw RequestError.internalError(detail: "the model slot switch failed")
    }
  }

  /// Restores the recorded session of `entry` onto the handle of `slot`.
  ///
  /// - Parameters:
  ///   - entry: The table entry of the session.
  ///   - slot: The slot to restore onto.
  /// - Returns: The restored session and its reports.
  /// - Throws: Whatever the restore throws.
  private func restoreSession(
    of entry: ActiveSession, onto slot: ModelSlot
  ) async throws -> RestoredSession {
    try await ConfigOptions.handle(for: slot, of: residentProfile)
      .restoreSessionWithHostChecks(
        id: entry.session.id,
        recordingRoot: entry.transcriptDirectory.deletingLastPathComponent(),
        instructions: entry.instructions,
        tools: entry.surface.tools,
        userPresence: entry.userPresence,
        hookSessionKey: HookLineage(workingDirectory: entry.workingDirectory, origin: .resumed)
          .sessionKey,
        transcriptReader: transcriptReader,
        switchingModel: true)
  }

  /// Gives the entry a restored session after a failed switch. The restore
  /// onto the old slot moves nothing, so it adds no event. When this restore
  /// fails too, the log has both errors and the Router session of the entry
  /// stays closed: the prompt that follows reports the closed session.
  ///
  /// - Parameters:
  ///   - entry: The table entry as it was before the switch.
  ///   - sessionId: The session.
  private func returnToSlot(of entry: ActiveSession, in sessionId: SessionId) async {
    do {
      let restored = try await restoreSession(of: entry, onto: entry.selectedSlot)
      await install(
        restored, in: sessionId, slot: entry.selectedSlot, replacing: entry.session.id)
    } catch {
      ACPAgentTelemetry.logger(.session).error(
        "The session could not return to its slot after a failed model slot switch.",
        metadata: ACPAgentTelemetry.errorMetadata(error, sessionId: sessionId))
    }
  }

  /// Puts a restored session into the entry. The projector reads the new
  /// session before any prompt can mail it, and the commands of the session
  /// act on it. A restore onto a smaller context than the recorded one runs
  /// no compaction, so the compaction starts here, once the projector reads
  /// the events of the session.
  ///
  /// - Parameters:
  ///   - restored: The restored session and its reports.
  ///   - sessionId: The ACP session.
  ///   - slot: The slot of the restored session.
  ///   - id: The id of the session root of the restore.
  private func install(
    _ restored: RestoredSession, in sessionId: SessionId, slot: ModelSlot, replacing id: ULID
  ) async {
    guard let entry = sessions[sessionId] else {
      await restored.session.close()
      return
    }
    await entry.projector.replace(with: restored.session)
    sessions[sessionId]?.session = restored.session
    sessions[sessionId]?.selectedSlot = slot
    entry.builtinContext?.replaceSession(restored.session)
    if restored.contextMismatches.contains(where: { $0.session == id && $0.resolved < $0.recorded })
    {
      _ = restored.session.compact()
    }
  }
}

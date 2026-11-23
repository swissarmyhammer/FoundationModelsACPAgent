import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The write of the retained history at the end of each transcript entry that Router recorded
/// (``ACPEventTranslator/entryRecorded``).
///
/// Before this write, the agent wrote the history file only at the end of a turn and at
/// `session/close`. A stop of the process during a turn then lost the turn from the replay.
///
/// The proofs hold a turn that has two Router submissions. A small compaction trigger makes the
/// first tool result stop the model call. Router records the entries of the first submission (the
/// prompt, the thought, the tool call and its output), compacts, and continues the same answer
/// with a continuation prompt. The second submission holds. The prompt of the client is open all
/// the time, so no end of a turn writes the file.
@Suite(.closesHarnesses) struct SessionHistoryEntryWriteTests {
  // MARK: - The script

  /// The prefix of the folders of this suite.
  private static let label = "SessionHistoryEntryWriteTests"

  /// The marker of the prompt of the client. Only the first submission plays the steps of the
  /// turn.
  private static let promptMarker = "ENTRY-WRITE-MARKER"

  /// The prompt of the client.
  private static let promptText = "Note the label, then go on. \(promptMarker)"

  /// The thought of the first submission.
  private static let thoughtText = "I note the label first."

  /// The label of the first call of the first submission.
  private static let noteLabel = "first label"

  /// The text of the second submission, after the hold.
  private static let finalText = "The work is done."

  /// The text of each other model call: the summary of the compaction.
  private static let summaryText = "A short summary."

  /// The start of the prompt that Router sends to continue an answer after a compaction at a
  /// tool result. Only the prompt of the second submission holds it.
  private static let continuationMarker = "The context was compacted."

  /// The project `config.yaml`: a compaction trigger that the first tool result crosses. The
  /// scripted counter gives one token for each character, and the instructions alone are more
  /// than this part of the context.
  private static let compactionYAML = "compaction:\n  trigger: 0.01\n  target: 0.005\n"

  /// The id of the call of the first submission: the first call of the scripted backend.
  private static let noteCallId = ScriptedSessionBackend.scriptedCallIdPrefix + "1"

  /// A tool that gives back its label.
  struct NoteTool: Tool {
    let name = "note"
    let description = "Note a label."

    func call(arguments: LabelArguments) async throws -> String {
      arguments.label
    }
  }

  /// The arguments of a call with `label`, as JSON.
  ///
  /// - Parameter label: The label.
  /// - Returns: The JSON text.
  private static func arguments(_ label: String) -> String {
    #"{"label":"\#(label)"}"#
  }

  /// The script. The first submission thinks and calls ``NoteTool`` two times. The first result
  /// stops the model call for the compaction. The second submission holds, then ends with
  /// ``finalText``. Each other model call, the summary of the compaction, gives ``summaryText``.
  ///
  /// - Parameter hold: The hold of the second submission.
  /// - Returns: The script.
  private static func script(holding hold: ScriptedHold) -> [ScriptedPassStep] {
    [
      .onPrompt(
        containing: promptMarker,
        play: [
          .reasoning(thoughtText),
          .toolCall(name: "note", argumentsJSON: arguments(noteLabel)),
          .toolCall(name: "note", argumentsJSON: arguments("second label")),
          .textDelta(finalText),
          .endPass,
        ]),
      .onPrompt(
        containing: continuationMarker,
        play: [.holdUntilReleased(hold), .textDelta(finalText), .endPass]),
      .textDelta(summaryText),
      .endPass,
    ]
  }

  /// Whether `updates` hold the `completed` status of the call of the first submission. The
  /// projector sends that status after the end of the `.toolCalls` entry of the call, thus after
  /// the write of that entry.
  ///
  /// - Parameter updates: The collected updates.
  /// - Returns: `true` when the status is there.
  private static func holdsCompletedNoteCall(_ updates: [UpdateSessionNotification]) -> Bool {
    updates.contains { notification in
      guard case .toolCallUpdate(let update) = notification.update else { return false }
      return update.toolCallId.rawValue == noteCallId && update.status == .value(.completed)
    }
  }

  /// The ids of the tool calls of `updates`.
  ///
  /// - Parameter updates: Session updates.
  /// - Returns: The ids, in order, one time each.
  private static func toolCallIds(in updates: [SessionUpdate]) -> [String] {
    var ids: [String] = []
    for update in updates {
      guard case .toolCallUpdate(let call) = update, !ids.contains(call.toolCallId.rawValue) else {
        continue
      }
      ids.append(call.toolCallId.rawValue)
    }
    return ids
  }

  /// Copies the folder at `source` to `destination`, which must not exist.
  ///
  /// - Parameters:
  ///   - source: The folder to copy.
  ///   - destination: The new folder.
  /// - Throws: Whatever the copy throws.
  private static func copyFolder(_ source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  // MARK: - The proofs

  /// While a turn holds after a recorded entry, the history file holds the user message, the
  /// thought and the tool call of the turn. A resume in a new agent over the recording as it was
  /// while the turn held (the state that a stop of the process leaves) replays them.
  @Test func aTurnThatHoldsAfterARecordedEntryHasThatEntryInTheHistoryFile() async throws {
    let hold = ScriptedHold()
    let folders = TestFolderLabel(Self.label)
    defer { folders.removeFolders() }
    let cwd = makeResolvedDirectory(label: "\(folders.value)-repo")
    let snapshot = makeResolvedDirectory(label: "\(folders.value)-snapshot")
    // The tool layers of Router see each tool result, so the compaction stops the model call at
    // the first result.
    let fixture = try await ScriptedPromptFixture.make(
      loader: makeHookLayeredModelLoader(script: Self.script(holding: hold)), label: folders.value,
      workingDirectory: cwd, projectConfigYAML: Self.compactionYAML, hostTools: [NoteTool()])
    let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
    let root = try ResumeSessionFixture.projectRecordingRoot(of: cwd)

    let response = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.promptText))
    _ = try await ScriptedPromptFixture.waitForUpdatesBeforeSettle(
      of: fixture.collector, toReach: "the completed status of the note call",
      Self.holdsCompletedNoteCall)

    // The reads while the turn holds give no throw, so the hold is released also when a read
    // fails.
    let written = try? SessionHistoryFile.read(from: entry.transcriptDirectory)
    // The state that a stop of the process leaves: the recording as it is while the turn holds.
    // The copy goes back in place of the recording after the first agent closed.
    let sessionFolder = root.appendingPathComponent(fixture.sessionId.rawValue, isDirectory: true)
    let held = snapshot.appendingPathComponent(fixture.sessionId.rawValue, isDirectory: true)
    let copied = Result { try Self.copyFolder(sessionFolder, to: held) }
    hold.release()
    _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
    await fixture.close()

    let file = try #require(written, "the history file is not on disk while the turn holds")
    let messages = ReplayedMessage.replayed(in: file.replayUpdates(from: .start))
    let kinds: [ReplayedMessage.Kind] = messages.map(\.kind)
    #expect(kinds == [.user, .thought], "the history file holds \(messages)")
    #expect(messages.first?.id == response.messageId.rawValue)
    #expect(messages.last?.text == Self.thoughtText)
    #expect(Self.toolCallIds(in: file.replayUpdates(from: .start)) == [Self.noteCallId])

    try copied.get()
    try FileManager.default.removeItem(at: sessionFolder)
    try Self.copyFolder(held, to: sessionFolder)

    let second = try await ScriptedPromptFixture.make(
      script: [.endPass], label: folders.value, workingDirectory: cwd, hostTools: [NoteTool()])
    let countBefore = await second.collector.updates.count
    do {
      _ = try await second.harness.connection.resumeSession(
        ResumeSessionRequest(
          cwd: AbsolutePath(rawValue: cwd.path), sessionId: fixture.sessionId,
          replayFrom: .start(ReplayFromStart())))
      let replay = Array(await second.collector.updates.dropFirst(countBefore)).map(\.update)
      let replayed = ReplayedMessage.replayed(in: replay)
      let replayedKinds: [ReplayedMessage.Kind] = replayed.prefix(2).map(\.kind)
      #expect(replayedKinds == [.user, .thought], "the replay holds \(replayed)")
      #expect(replayed.first?.id == response.messageId.rawValue)
      #expect(replayed.dropFirst().first?.text == Self.thoughtText)
      #expect(Self.toolCallIds(in: replay).first == Self.noteCallId)
      await second.close()
    } catch {
      await second.close()
      throw error
    }
  }
}

import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import FoundationModelsSkills
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// Two default sessions in one folder, on the real in-process stack of the agent (D200): the
/// Router session directory, the `sessions` tool of Multitool, and the skills stack with the
/// built-in skills of Multitool. Only the model is a script.
///
/// The `default` agent of the folder names the built-in skill in its `skills:` key, as the
/// default agent of the skills marketplace does. The suites of this package are offline, thus the
/// agent reads no marketplace, and the folder gives the agent.
///
/// The first session is the sender, and the source session of a message from the user. The
/// second session is the target.
struct SessionsSkillScenario {
  // MARK: - Constants

  /// The id of the built-in skill.
  private static let sessionsSkillID = "sessions"

  /// The name of the `sessions` tool.
  private static let sessionsToolName = "sessions"

  /// The `skills:` key of the `default` agent that preloads the built-in skill.
  private static let skillsKey = "skills: [\(sessionsSkillID)]"

  /// The prompt of the first session that makes its script call the `sessions` tool.
  private static let sendMarker = "SESSIONS-SKILL-SEND"

  /// The answer of each other pass of the script.
  private static let answerText = "SESSIONS-SKILL-ANSWER"

  /// The client id of the UI that sends a message from the user.
  private static let clientID = "testudo-ui"

  /// The start of each receipt line in the answer of `send message`.
  private static let receiptLinePrefix = "- "

  /// The count of milliseconds in one second.
  private static let millisecondsPerSecond = 1_000

  /// The time between two reads of a state that a test waits for, in milliseconds.
  private static let waitIntervalMilliseconds = 10

  /// The longest time that a test waits for a state, in seconds.
  private static let waitLimitSeconds = 20

  /// The time between two reads of a state that a test waits for.
  private static let waitInterval = Duration.milliseconds(waitIntervalMilliseconds)

  /// The most reads of a state that a test waits for: ``waitLimitSeconds`` at
  /// ``waitInterval``.
  private static let waitPolls = waitLimitSeconds * millisecondsPerSecond / waitIntervalMilliseconds

  // MARK: - State

  /// The harness of the agent.
  let harness: AgentClientHarness

  /// The record of each prompt that the model of a session got.
  private let recorder: PromptRecorder

  /// The sender, and the source session of a message from the user.
  let first: SessionId

  /// The target.
  let second: SessionId

  /// The file with the arguments of the `sessions` call of the script.
  private let argumentsFile: URL

  /// The session directory of the agent.
  var directory: RouterSessionDirectory {
    harness.agent.sessionDirectory
  }

  // MARK: - Make and close

  /// Makes the agent and opens the two sessions in one new folder.
  ///
  /// - Parameter label: The label of the folders of the test.
  /// - Returns: The scenario.
  /// - Throws: Whatever the writes, the construction, the handshake or `session/new` throw.
  static func make(label: String) async throws -> SessionsSkillScenario {
    let folder = makeResolvedDirectory(label: "\(label)-repo")
    let argumentsFile = makeResolvedDirectory(label: "\(label)-call")
      .appendingPathComponent("send.json")
    try AgentFolderFixture.writeProjectAgent(
      id: ConfigOptions.defaultAgentValue, in: folder, extraKeys: [skillsKey])
    let recorder = PromptRecorder()
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: sendMarker,
        play: [.toolCallFromFile(name: sessionsToolName, path: argumentsFile.path), .endPass]),
      .textDelta(answerText),
      .endPass,
    ]
    let agent = try await makeStubAgent(
      name: AgentClientHarness.dotfolderName,
      cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
      recordingsDirectory: makeResolvedDirectory(label: "\(label)-recordings"),
      userDirectory: makeResolvedDirectory(label: "\(label)-user"),
      loader: makeScriptedModelLoader(script: script, recorder: recorder))
    let harness = await AgentClientHarness.makeRecording(agent: agent)
    _ = try await harness.client.initialize(AgentClientHarness.makeInitializeRequest())
    let request = AgentClientHarness.makeNewSessionRequest(cwd: folder)
    let first = try await harness.connection.newSession(request).sessionId
    let second = try await harness.connection.newSession(request).sessionId
    return SessionsSkillScenario(
      harness: harness, recorder: recorder, first: first, second: second,
      argumentsFile: argumentsFile)
  }

  /// Closes each session with `session/close`, then closes the harness. The close of a session
  /// returns after the session sent each update, thus no turn of the target sends an update after
  /// the wire closed. A failed close records an issue.
  func close() async {
    for session in [first, second] {
      do {
        _ = try await harness.connection.closeSession(CloseSessionRequest(sessionId: session))
      } catch {
        Issue.record("session/close of \(session.rawValue) failed: \(error)")
      }
    }
    await harness.close()
  }

  // MARK: - The skill

  /// The body of the built-in `sessions` skill as the preload renders it, with no leading or
  /// trailing white space.
  ///
  /// - Returns: The body.
  /// - Throws: What the render of the skill throws.
  static func sessionsSkillBody() async throws -> String {
    try await SkillsRegistry(roots: [BuiltinSkills.directory], mode: .open)
      .call(id: sessionsSkillID)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The assembled instructions of a session.
  ///
  /// - Parameter session: The session.
  /// - Returns: The instructions.
  /// - Throws: An issue when the agent has no such session.
  func instructions(of session: SessionId) async throws -> String {
    try #require(await harness.agent.sessions[session]?.instructions)
  }

  // MARK: - The sends

  /// The first session sends `text` to the second session with the `sessions` tool: its script
  /// calls the tool in a turn.
  ///
  /// - Parameter text: The text of the message.
  /// - Returns: The receipt lines of the answer of the tool, as the client of the first session
  ///   got them.
  /// - Throws: Whatever the write of the arguments or the prompt throws.
  func sendWithTheSessionsTool(_ text: String) async throws -> [String] {
    let arguments = ["op": "send message", "to": "@\(second.rawValue)", "message": text]
    try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
      .write(to: argumentsFile, options: .atomic)
    _ = try await harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: first, text: Self.sendMarker))
    let collector = try #require(harness.collector)
    let sender = first
    try await pollUntil(limit: Self.waitPolls, interval: Self.waitInterval) {
      !Self.receiptLines(in: await collector.updates, of: sender).isEmpty
    }
    return Self.receiptLines(in: await collector.updates, of: sender)
  }

  /// The user sends `text` to the second session through the session directory, as the UI of a
  /// session does.
  ///
  /// - Parameters:
  ///   - text: The text of the message.
  ///   - source: The session in which the user wrote the message.
  /// - Throws: Whatever the send throws.
  func sendAsTheUser(_ text: String, from source: ULID) async throws {
    let target = try Self.ulid(of: second)
    _ = try await directory.send(
      OutgoingSessionMessage(
        from: .user(clientID: Self.clientID), to: .session(target), text: text,
        sourceSession: source))
  }

  /// The id of a session in the directory.
  ///
  /// - Parameter session: The session.
  /// - Returns: The id.
  /// - Throws: An issue when the id is not a ULID.
  static func ulid(of session: SessionId) throws -> ULID {
    try #require(ULID(ulidString: session.rawValue))
  }

  /// The receipt word of a receipt line: its first word, in lower case.
  ///
  /// - Parameter line: A receipt line of the answer of `send message`.
  /// - Returns: The word.
  static func receiptWord(of line: String) -> String {
    line.dropFirst(receiptLinePrefix.count).prefix { $0.isLetter }.lowercased()
  }

  /// The prompts that the models got with `text` in them. It waits, for at most
  /// ``waitLimitSeconds``, until one prompt has the text.
  ///
  /// - Parameter text: The text of a message.
  /// - Returns: The prompts with the text, in order. It is empty when no prompt came in time.
  /// - Throws: The cancel of the wait.
  func prompts(holding text: String) async throws -> [String] {
    let recorder = self.recorder
    try await pollUntil(limit: Self.waitPolls, interval: Self.waitInterval) {
      await recorder.prompts.contains { $0.contains(text) }
    }
    return await recorder.prompts.filter { $0.contains(text) }
  }

  // MARK: - The wire

  /// The receipt lines that the client of `session` got in the content of a tool call. The
  /// text of the answer of a tool is a JSON string in the content, thus each text is decoded
  /// first.
  ///
  /// - Parameters:
  ///   - notifications: The updates that the client got.
  ///   - session: The session of the tool call.
  /// - Returns: The distinct receipt lines, sorted.
  private static func receiptLines(
    in notifications: [UpdateSessionNotification], of session: SessionId
  ) -> [String] {
    let texts = notifications.filter { $0.sessionId == session }.flatMap { notification in
      guard case .toolCallUpdate(let update) = notification.update,
        case .value(let items) = update.content
      else {
        return [String]()
      }
      return items.compactMap { item in
        guard case .content(let wrapped) = item, case .text(let text) = wrapped.content else {
          return nil
        }
        return decodedText(text.text)
      }
    }
    let lines = texts.flatMap { $0.components(separatedBy: "\n") }
    return Set(lines.filter { $0.hasPrefix(receiptLinePrefix) }).sorted()
  }

  /// The value of a content text that is a JSON string, else the text as it is.
  ///
  /// - Parameter text: A text of the content of a tool call.
  /// - Returns: The decoded text.
  private static func decodedText(_ text: String) -> String {
    (try? JSONDecoder().decode(String.self, from: Data(text.utf8))) ?? text
  }
}

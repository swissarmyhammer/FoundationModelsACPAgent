import Foundation
import FoundationModels
import FoundationModelsMultitool
import FoundationModelsRouter
import Synchronization

/// A session backend that plays a script: text deltas, known tool calls
/// with fixed arguments, and a pass end.
///
/// The ``ScriptedPlaybook`` of the backend gives the steps of each
/// generating call. A playbook of one script plays that script from the
/// start at every call.
///
/// The synthesized transcript has the shape a real model session's has,
/// so a recording over it is a recording of a real pass shape (task
/// ^jz016kq):
///
/// - one leading `.instructions` entry, made once and never rewritten,
///   carrying the session instructions and one `Transcript.ToolDefinition`
///   per handed tool;
/// - one `.prompt` entry per generating call, before the play;
/// - one `.reasoning` entry in a pass that plays a
///   ``ScriptedPassStep/reasoning(_:)`` step. Each such step makes its text
///   longer, and ``transcriptUpdates()`` shows each change while the pass
///   runs, as the live SDK session does (task ^k51h6bb);
/// - a `.toolCalls` entry before each played invocation and a
///   `.toolOutput` entry after it, so Router's transcript diff derives
///   the `toolCall` and `toolStatus` session events for the tier-2
///   projection proofs;
/// - one `.response` entry after a play that reached the pass end. A
///   failing or cancelled play appends none, as a real failed pass
///   records none.
///
/// The entries are SDK `Transcript` values with public initializers,
/// never Router recording values.
///
/// A class, not a struct, because `LanguageModelSessionBackend`
/// requires `AnyObject`. The one mutable member is guarded by a
/// `Mutex`, so its `Sendable` conformance stays compiler-checked.
public final class ScriptedSessionBackend: LanguageModelSessionBackend {
  /// The token usage every scripted backend reports, in the pattern
  /// of `EchoSessionBackend`: a constant one/one, so a usage consumer
  /// observes a report.
  private static let scriptedUsage = (input: 1, output: 1)

  /// The prefix of every synthesized SDK tool-call id. The suffix is
  /// the one-based ordinal of the call, so a test addresses the first
  /// scripted call as `scripted-call-1`.
  public static let scriptedCallIdPrefix = "scripted-call-"

  /// The schema name the synthesized structured output segment
  /// declares. The value only satisfies the SDK initializer.
  private static let outputSchemaName = "ScriptedToolOutput"

  /// The synthesized transcript of one backend: the SDK entries the
  /// played tool calls appended, and how many tool calls played —
  /// the source of the deterministic scripted call ids.
  private struct SynthesizedTranscript {
    /// The appended SDK entries, in append order.
    var entries: [Transcript.Entry] = []

    /// The number of tool calls played so far.
    var playedToolCallCount = 0

    /// The `.reasoning` entry of the pass in flight, or `nil` before
    /// the first reasoning step of the pass.
    var liveReasoning: LiveReasoning?

    /// The continuation of each open ``transcriptUpdates()`` stream, by
    /// the key of the stream.
    var observers: [Int: AsyncStream<[Transcript.Entry]>.Continuation] = [:]

    /// The key of the next ``transcriptUpdates()`` stream.
    var nextObserverKey = 0
  }

  /// The `.reasoning` entry that the reasoning steps of one pass make
  /// longer: its place in the entries, its stable id, and its text.
  private struct LiveReasoning {
    /// The index of the entry in ``SynthesizedTranscript/entries``.
    let index: Int

    /// The id of the entry. It stays the same while the text grows, as
    /// the id of a live SDK entry does.
    let id: String

    /// The text of the entry so far.
    var text: String
  }

  /// The synthesized transcript, guarded for the sync
  /// `transcriptEntries()` read against the async playback append.
  private let synthesized = Mutex(SynthesizedTranscript())

  /// The playbook that gives the steps of each generating call.
  private let playbook: ScriptedPlaybook

  /// The tools the session was handed; `toolCall` steps invoke them.
  private let tools: [any Tool]

  /// The session instructions the leading `.instructions` entry
  /// carries, or `nil` when the session was made without any.
  private let instructions: String?

  /// The observer of this backend, or `nil` when no test observes it.
  /// Each fork and each replaced transcript has the same observer.
  private let observer: (any ScriptedBackendObserver)?

  /// Creates a backend that plays `playbook` against `tools`.
  ///
  /// - Parameters:
  ///   - playbook: The playbook that gives the steps of each call.
  ///   - tools: The tools `toolCall` steps invoke.
  ///   - instructions: The session instructions the leading
  ///     `.instructions` entry carries, or `nil` for none.
  ///   - seededEntries: The transcript a restored session starts from,
  ///     in place of a fresh leading `.instructions` entry. Empty for
  ///     a fresh session.
  ///   - observer: The observer of the backend, or `nil` (the default)
  ///     to observe nothing and to play each call directly.
  public init(
    playbook: ScriptedPlaybook,
    tools: [any Tool],
    instructions: String? = nil,
    seededEntries: [Transcript.Entry] = [],
    observer: (any ScriptedBackendObserver)? = nil
  ) {
    observer?.backendMade()
    self.playbook = playbook
    self.tools = tools
    self.instructions = instructions
    self.observer = observer
    let opening =
      seededEntries.isEmpty
      ? [Self.instructionsEntry(instructions: instructions, tools: tools)]
      : seededEntries
    synthesized.withLock { $0.entries = opening }
  }

  /// Plays one pass of the script for `prompt`.
  ///
  /// - Parameters:
  ///   - prompt: The prompt the pass answers.
  ///   - maxTokens: The token ceiling, which the script ignores.
  /// - Returns: The text that the pass played.
  /// - Throws: What the play throws, for example a step that fails.
  public func respond(to prompt: String, maxTokens: Int?) async throws -> String {
    try await playPass(prompt: prompt) { _ in }
  }

  /// Plays one pass of the script for `prompt`. The script has no sampler,
  /// so the grammar does not restrict the answer.
  ///
  /// - Parameters:
  ///   - prompt: The prompt the pass answers.
  ///   - grammar: The grammar of the answer, which the script ignores.
  ///   - maxTokens: The token ceiling, which the script ignores.
  /// - Returns: The text that the pass played.
  /// - Throws: What the play throws, for example a step that fails.
  public func respond(
    to prompt: String, following grammar: Grammar, maxTokens: Int?
  ) async throws -> String {
    try await respond(to: prompt, maxTokens: maxTokens)
  }

  /// Plays one pass of the script for `prompt`, and streams the text of the
  /// pass as it plays.
  ///
  /// - Parameters:
  ///   - prompt: The prompt the pass answers.
  ///   - maxTokens: The token ceiling, which the script ignores.
  /// - Returns: A stream of the text chunks of the pass. It ends with the
  ///   error of a play that throws.
  public func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<
    String, Error
  > {
    AsyncThrowingStream { continuation in
      let playback = Task {
        do {
          _ = try await playPass(prompt: prompt) { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in playback.cancel() }
    }
  }

  /// Makes a fork that starts from the entries of this backend now.
  ///
  /// - Returns: A new backend with a sibling of the playbook.
  public func makeFork() -> any LanguageModelSessionBackend {
    makeSibling(seededEntries: transcriptEntries())
  }

  /// Makes a backend that continues from `transcript`, not from this
  /// backend's own entries.
  ///
  /// Router calls this after a compaction fold, with the folded
  /// transcript. The protocol default ignores `transcript` and forks, so
  /// without this override a fold never reaches the transcript that a
  /// scripted session reports.
  ///
  /// - Parameter transcript: The transcript the new backend starts from.
  /// - Returns: A backend with a sibling of this playbook, these tools and `transcript`.
  public func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
    makeSibling(seededEntries: Array(transcript))
  }

  /// Makes a backend with a sibling of this playbook, these tools and this
  /// observer, that starts from `seededEntries`. A fork and a replaced
  /// transcript thus take the model lock of the same observer.
  ///
  /// - Parameter seededEntries: The transcript the new backend starts from.
  /// - Returns: The new backend.
  private func makeSibling(seededEntries: [Transcript.Entry]) -> ScriptedSessionBackend {
    Self.makeSibling(
      of: playbook,
      tools: tools,
      instructions: instructions,
      seededEntries: seededEntries,
      observer: observer)
  }

  /// Makes a backend over a sibling of `playbook` that continues the
  /// script of `seededEntries`. This is the one place that builds a sibling
  /// backend, for a fork, a replaced transcript and a container session,
  /// fresh or restored.
  ///
  /// - Parameters:
  ///   - playbook: The playbook to take a sibling of.
  ///   - tools: The tools `toolCall` steps invoke.
  ///   - instructions: The session instructions, or `nil` for none.
  ///   - seededEntries: The transcript the new backend starts from, or
  ///     empty for a fresh session.
  ///   - observer: The observer of the new backend, or `nil` for none.
  /// - Returns: The new backend.
  static func makeSibling(
    of playbook: ScriptedPlaybook,
    tools: [any Tool],
    instructions: String?,
    seededEntries: [Transcript.Entry],
    observer: (any ScriptedBackendObserver)?
  ) -> ScriptedSessionBackend {
    ScriptedSessionBackend(
      playbook: playbook.makeSibling(continuing: seededEntries),
      tools: tools,
      instructions: instructions,
      seededEntries: seededEntries,
      observer: observer)
  }

  deinit {
    observer?.backendReleased()
  }

  /// The transcript entries of the backend now.
  ///
  /// - Returns: The opening entry and the entries that the played passes
  ///   appended.
  public func transcriptEntries() -> [Transcript.Entry] {
    // The SDK entries the played tool calls appended. Router's
    // transcript diff reads them and derives the `toolCall` and
    // `toolStatus` session events, the way it does for a real
    // model session.
    synthesized.withLock { $0.entries }
  }

  /// The transcript of this backend now, and again after each change of
  /// it, while the stream is read (task ^k51h6bb).
  ///
  /// Router's repetition watch reads this stream while a call is in
  /// flight. A backend that keeps the protocol default gives no value,
  /// and Router does not watch its calls. Values that come faster than
  /// the reader reads merge into the newest one, as the contract permits.
  ///
  /// - Returns: The stream of the transcript.
  public func transcriptUpdates() -> AsyncStream<[Transcript.Entry]> {
    let (stream, continuation) = AsyncStream<[Transcript.Entry]>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let key = synthesized.withLock { state in
      let key = state.nextObserverKey
      state.nextObserverKey += 1
      state.observers[key] = continuation
      // This yield under the lock is safe: the stream is new, thus no
      // reader waits on it and no `onTermination` handler is set yet.
      // The yield only keeps the value in the buffer. It keeps the
      // first value and the later changes in order.
      continuation.yield(state.entries)
      return key
    }
    continuation.onTermination = { [weak self] _ in
      self?.observer?.updateStreamEnded()
      self?.synthesized.withLock { state in
        _ = state.observers.removeValue(forKey: key)
      }
    }
    return stream
  }

  /// The token counts of the last answer.
  ///
  /// - Returns: The fixed counts of a scripted pass.
  public func usageTokenCounts() -> (input: Int, output: Int)? {
    Self.scriptedUsage
  }

  /// Plays one whole pass: records the prompt, appends the pass's
  /// `.prompt` entry, plays the script, and appends the pass's
  /// `.response` entry.
  ///
  /// A play that throws appends no `.response` entry, because a real
  /// model session records none for a pass that never answered.
  ///
  /// With an observer that gives a turn, the play first waits for the model
  /// lock of the observer. The play holds the model from its start to its
  /// end, also when the play throws, and it leaves the model for each tool
  /// body.
  ///
  /// - Parameters:
  ///   - prompt: The prompt the pass answers.
  ///   - yield: Receives each text delta, in order.
  /// - Returns: The answer text, the deltas joined in order.
  /// - Throws: `CancellationError` when the task is cancelled while the
  ///   pass waits for the model, or whatever
  ///   ``play(_:prompt:turn:yield:)`` throws.
  private func playPass(prompt: String, yield: (String) -> Void) async throws -> String {
    let turn = try await observer?.passWillStart(prompt: prompt)
    defer { turn?.end() }
    appendPromptEntry(prompt: prompt)
    var text = ""
    _ = try await play(playbook.steps(forPrompt: prompt), prompt: prompt, turn: turn) { delta in
      text += delta
      yield(delta)
    }
    appendResponseEntry(text: text)
    return text
  }

  /// The leading `.instructions` entry of a fresh scripted session:
  /// the instructions text, and one tool definition per handed tool.
  ///
  /// The entry is made once, in `init`, and never rewritten. Its
  /// stability across passes is what task ^jz016kq proves.
  ///
  /// - Parameters:
  ///   - instructions: The instructions text, or `nil` for none.
  ///   - tools: The tools the session was handed.
  /// - Returns: The entry.
  private static func instructionsEntry(
    instructions: String?, tools: [any Tool]
  ) -> Transcript.Entry {
    let segments: [Transcript.Segment] =
      instructions.map { [.text(Transcript.TextSegment(content: $0))] } ?? []
    return .instructions(
      Transcript.Instructions(
        segments: segments,
        toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }))
  }

  /// Appends the `.prompt` entry of one pass.
  ///
  /// - Parameter prompt: The prompt the pass answers.
  private func appendPromptEntry(prompt: String) {
    let entry = Transcript.Entry.prompt(
      Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))]))
    changeTranscript { state in
      state.entries.append(entry)
      state.liveReasoning = nil
    }
  }

  /// Changes the synthesized transcript with `change`, and gives the
  /// changed entries to each open ``transcriptUpdates()`` stream.
  ///
  /// The delivery occurs after the lock is released (task ^05rmb1p). A
  /// yield can resume a reader task, and the runtime then takes the status
  /// lock of that task. A cancel of that reader holds the same status lock
  /// while it runs the `onTermination` handler of the stream, and that
  /// handler takes the lock of the transcript. A yield under the lock thus
  /// stops both threads.
  ///
  /// The passes of one backend run one at a time, thus the changes come
  /// from one task, in order, and each delivery goes out before the next
  /// change.
  ///
  /// - Parameter change: The change to make, under the lock.
  /// - Returns: What `change` returns.
  private func changeTranscript<Result: Sendable>(
    _ change: (inout SynthesizedTranscript) -> Result
  ) -> Result {
    let (result, entries, observers) = synthesized.withLock { state in
      (change(&state), state.entries, Array(state.observers.values))
    }
    observer?.transcriptWillDeliver()
    for observer in observers {
      observer.yield(entries)
    }
    return result
  }

  /// Adds `text` to the `.reasoning` entry of the pass in flight, and
  /// makes that entry when the pass has none yet.
  ///
  /// - Parameter text: The reasoning text to add.
  private func appendReasoning(_ text: String) {
    changeTranscript { state in
      var reasoning =
        state.liveReasoning
        ?? LiveReasoning(index: state.entries.count, id: UUID().uuidString, text: "")
      reasoning.text += text
      let entry = Transcript.Entry.reasoning(
        Transcript.Reasoning(
          id: reasoning.id,
          segments: [.text(Transcript.TextSegment(content: reasoning.text))],
          signature: nil))
      if state.entries.indices.contains(reasoning.index) {
        state.entries[reasoning.index] = entry
      } else {
        state.entries.append(entry)
      }
      state.liveReasoning = reasoning
    }
  }

  /// Appends the `.response` entry that closes one pass.
  ///
  /// - Parameter text: The answer text the play produced.
  private func appendResponseEntry(text: String) {
    let entry = Transcript.Entry.response(
      Transcript.Response(segments: [.text(Transcript.TextSegment(content: text))]))
    changeTranscript { $0.entries.append(entry) }
  }

  /// Plays `steps`: yields each delta, invokes each scripted tool call,
  /// plays the steps of each ``ScriptedPassStep/onPrompt(containing:play:)``
  /// whose marker `prompt` contains, and stops at the pass end.
  ///
  /// - Parameters:
  ///   - steps: The steps to play, in order.
  ///   - prompt: The prompt the pass answers.
  ///   - turn: The hold of the model by the pass, or `nil` for a pass
  ///     that takes no model lock.
  ///   - yield: Receives each text delta, in order.
  /// - Returns: `true` when an ``ScriptedPassStep/endPass`` step ended
  ///   the play, and `false` when the play ran out of steps.
  /// - Throws: ``ScriptedModelError/unknownTool(_:)`` for a tool the
  ///   session was not handed, or the invoked tool's own error.
  private func play(
    _ steps: [ScriptedPassStep], prompt: String, turn: (any ScriptedPassTurn)?,
    yield: (String) -> Void
  ) async throws -> Bool {
    for step in steps {
      switch step {
      case .textDelta(let text):
        yield(text)
      case .reasoning(let text):
        appendReasoning(text)
      case .toolCall(let name, let argumentsJSON):
        try await invokeTool(named: name, argumentsJSON: argumentsJSON, turn: turn)
      case .toolCallFromFile(let name, let path):
        try await ScriptedGate.wait(atPath: path)
        let argumentsJSON = try String(contentsOfFile: path, encoding: .utf8)
        try await invokeTool(named: name, argumentsJSON: argumentsJSON, turn: turn)
      case .elicit, .permission:
        if let arguments = try Self.questionArguments(of: step),
          try await askUser(runCodeArguments: arguments, turn: turn, yield: yield)
        {
          return true
        }
      case .fail(let failure):
        throw failure.error
      case .hold:
        try await Self.holdUntilCancelled()
      case .holdUntilReleased(let hold):
        try await hold.waitForRelease()
      case .gate(let path):
        try await ScriptedGate.wait(atPath: path)
      case .writeFile(let path, let text):
        try Self.write(text: text, toFileAt: path)
      case .onPrompt(let marker, let branch):
        if prompt.contains(marker), try await play(branch, prompt: prompt, turn: turn, yield: yield)
        {
          return true
        }
      case .endPass:
        return true
      }
    }
    return false
  }

  /// The arguments of the `runCode` call of a question step.
  ///
  /// - Parameter step: An ``ScriptedPassStep/elicit(message:)`` or
  ///   ``ScriptedPassStep/permission(title:)`` step.
  /// - Returns: The arguments, as JSON, or `nil` for any other step.
  /// - Throws: The encoding error.
  private static func questionArguments(of step: ScriptedPassStep) throws -> String? {
    switch step {
    case .elicit(let message): try ScriptedElicitation.runCodeArguments(asking: message)
    case .permission(let title): try ScriptedPermission.runCodeArguments(asking: title)
    default: nil
    }
  }

  /// Plays one question step: the `runCode` call that asks the user, as
  /// ``ScriptedElicitation`` and ``ScriptedPermission`` describe it.
  ///
  /// - Parameters:
  ///   - runCodeArguments: The arguments of the `runCode` call that asks.
  ///   - turn: The hold of the model by the pass, or `nil` for a pass
  ///     that takes no model lock.
  ///   - yield: Receives the text that ends a pass whose question got no
  ///     answer.
  /// - Returns: `true` when the question got no answer. The text of the
  ///   refusal was then yielded, and the pass must end. `false` when the
  ///   user answered.
  /// - Throws: What ``invokeTool(named:argumentsJSON:turn:)`` throws.
  private func askUser(
    runCodeArguments: String, turn: (any ScriptedPassTurn)?, yield: (String) -> Void
  ) async throws -> Bool {
    let output = try await invokeTool(
      named: NoOpToolCall.runCodeToolName, argumentsJSON: runCodeArguments, turn: turn)
    guard let refusal = ScriptedElicitation.refusal(inOutput: String(describing: output)) else {
      return false
    }
    yield(refusal.text)
    return true
  }

  /// Suspends until the surrounding task is cancelled, then throws
  /// `CancellationError`. A never-yielding stream carries the wait, so
  /// only a cancellation ends the iteration.
  private static func holdUntilCancelled() async throws {
    let (stream, continuation) = AsyncStream<Never>.makeStream()
    for await _ in stream {}
    withExtendedLifetime(continuation) {}
    try Task.checkCancellation()
  }

  /// Writes `text` to the file at `path`.
  ///
  /// The handle is opened for UPDATING, thus `O_RDWR`. A named pipe
  /// opened that way never waits for the other end, so a step that
  /// releases a held run through a pipe cannot hang the pass, and the
  /// close is still the only writer's close, thus the reading run sees
  /// the end of the stream. A path that holds no file yet is made.
  ///
  /// - Parameters:
  ///   - text: The text to write.
  ///   - path: The file to write it to.
  /// - Throws: The write error.
  private static func write(text: String, toFileAt path: String) throws {
    guard let handle = FileHandle(forUpdatingAtPath: path) else {
      try text.write(toFile: path, atomically: true, encoding: .utf8)
      return
    }
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
  }

  /// Invokes the handed tool `name` with the fixed arguments, and
  /// appends the SDK transcript entries a real model session records
  /// around a tool call: `.toolCalls` before the invocation, and
  /// `.toolOutput` after it. Router's transcript diff derives the
  /// `toolCall` and `toolStatus` session events from them.
  ///
  /// The tool body runs with no model lock: the pass leaves the model
  /// before the body, and waits for it again after the body.
  ///
  /// - Parameters:
  ///   - name: The name of the tool to invoke.
  ///   - argumentsJSON: The fixed arguments, as JSON.
  ///   - turn: The hold of the model by the pass, or `nil` for a pass
  ///     that takes no model lock.
  /// - Returns: The value the tool returned.
  /// - Throws: ``ScriptedModelError/unknownTool(_:)`` when no handed
  ///   tool has `name`, `CancellationError` when the task is cancelled
  ///   while the pass waits for the model again, or the tool's own error.
  @discardableResult
  private func invokeTool(
    named name: String, argumentsJSON: String, turn: (any ScriptedPassTurn)?
  ) async throws -> Any {
    guard let tool = tools.first(where: { $0.name == name }) else {
      throw ScriptedModelError.unknownTool(name)
    }
    let content = try GeneratedContent(json: argumentsJSON)
    let callId = appendToolCallsEntry(name: name, arguments: content)
    turn?.leave()
    let output = try await ToolInvoker.invoke(tool, content: content)
    try await turn?.takeAgain()
    appendToolOutputEntry(callId: callId, name: name, output: output)
    return output
  }

  /// Appends the `.toolCalls` entry of one played call and mints the
  /// call's deterministic id.
  ///
  /// - Parameters:
  ///   - name: The invoked tool's name.
  ///   - arguments: The call's arguments.
  /// - Returns: The minted scripted call id.
  private func appendToolCallsEntry(name: String, arguments: GeneratedContent) -> String {
    changeTranscript { state in
      state.playedToolCallCount += 1
      let callId = Self.scriptedCallIdPrefix + String(state.playedToolCallCount)
      state.entries.append(
        .toolCalls(
          Transcript.ToolCalls(
            id: callId + "-batch",
            [Transcript.ToolCall(id: callId, toolName: name, arguments: arguments)])))
      return callId
    }
  }

  /// Appends the `.toolOutput` entry that answers one played call.
  ///
  /// The output rides as a structured segment when the value converts
  /// to `GeneratedContent` — every session-tool output is a `String`,
  /// which does — so the projection's `rawOutput` reads the real
  /// value. Any other output degrades to a text segment.
  ///
  /// - Parameters:
  ///   - callId: The scripted call id the output answers.
  ///   - name: The invoked tool's name.
  ///   - output: The value the tool returned.
  private func appendToolOutputEntry(callId: String, name: String, output: Any) {
    let segment: Transcript.Segment
    if let convertible = output as? any ConvertibleToGeneratedContent {
      segment = .structure(
        Transcript.StructuredSegment(
          id: callId + "-output",
          schemaName: Self.outputSchemaName,
          content: convertible.generatedContent))
    } else {
      segment = .text(Transcript.TextSegment(content: String(describing: output)))
    }
    changeTranscript { state in
      state.entries.append(
        .toolOutput(
          Transcript.ToolOutput(id: callId, toolName: name, segments: [segment])))
    }
  }
}

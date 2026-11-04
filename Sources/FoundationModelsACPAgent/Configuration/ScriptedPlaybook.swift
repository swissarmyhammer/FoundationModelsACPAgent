import Foundation
import FoundationModels
import FoundationModelsRouter
import Synchronization

// MARK: - The playbook of a scripted backend
//
// A scripted backend asks its playbook for the steps of each model call.
// There are two plans:
//
// - One script that every call plays from the start. The in-process tests
//   use it.
// - A ``ScriptedStubScript`` of sessions. The session of a backend is
//   chosen by its first prompt, and its passes play in order. The
//   `ACP_AGENT_STUB_SCRIPT` stub path of the `acp-agent` binary uses it.

/// Gives the steps of each model call of one scripted backend.
///
/// A class, because the plan of sessions keeps the progress of its backend:
/// the session that its first prompt chose, and the passes that played.
public final class ScriptedPlaybook: Sendable {
  /// What the playbook plays.
  private enum Plan: Sendable {
    /// The same steps at every call.
    case everyPass([ScriptedPassStep])

    /// The sessions of a script, chosen by the first prompt.
    case sessions(ScriptedStubScript)
  }

  /// The progress of a playbook of sessions.
  private struct Progress {
    /// The passes of the chosen session, or `nil` before the first
    /// call. An empty list is a session that no entry matched: it
    /// echoes.
    var passes: [[ScriptedPassStep]]?

    /// The index of the next pass to play.
    var nextPass = 0
  }

  /// The plan.
  private let plan: Plan

  /// The progress, under one lock. A playbook of one script never reads
  /// it.
  private let progress = Mutex(Progress())

  /// Makes a playbook of a plan.
  ///
  /// - Parameter plan: The plan.
  private init(plan: Plan) {
    self.plan = plan
  }

  /// Makes a playbook that plays `steps` from the start at every call.
  ///
  /// - Parameter steps: The steps of each call.
  /// - Returns: The playbook.
  public static func everyPass(_ steps: [ScriptedPassStep]) -> ScriptedPlaybook {
    ScriptedPlaybook(plan: .everyPass(steps))
  }

  /// Makes a playbook of the sessions of `script`. The first prompt of the
  /// backend chooses the session. Its passes play in order, one for each
  /// call. After the last pass, and for a prompt that no session matches,
  /// each call echoes the prompt.
  ///
  /// - Parameter script: The script that holds the sessions.
  /// - Returns: The playbook.
  public static func sessions(_ script: ScriptedStubScript) -> ScriptedPlaybook {
    ScriptedPlaybook(plan: .sessions(script))
  }

  /// Makes the playbook of a backend that forks from this one, or that
  /// continues from a replaced transcript. It plays as a new backend
  /// would: a playbook of sessions starts again and chooses by its own
  /// first prompt.
  ///
  /// - Returns: The playbook of the new backend.
  func makeSibling() -> ScriptedPlaybook {
    switch plan {
    case .everyPass:
      self
    case .sessions(let script):
      ScriptedPlaybook(plan: .sessions(script))
    }
  }

  /// The steps of the next model call.
  ///
  /// - Parameter prompt: The prompt of the call.
  /// - Returns: The steps to play.
  func steps(forPrompt prompt: String) -> [ScriptedPassStep] {
    switch plan {
    case .everyPass(let steps):
      return steps
    case .sessions(let script):
      return nextPass(of: script, prompt: prompt) ?? [.textDelta(prompt)]
    }
  }

  /// Takes the next pass of the session of the backend.
  ///
  /// - Parameters:
  ///   - script: The script that holds the sessions.
  ///   - prompt: The prompt of the call. At the first call it chooses the
  ///     session.
  /// - Returns: The pass, or `nil` when no pass is left, and for a session
  ///   that no entry matched.
  private func nextPass(of script: ScriptedStubScript, prompt: String) -> [ScriptedPassStep]? {
    progress.withLock { progress in
      let passes = progress.passes ?? script.passes(forFirstPrompt: prompt) ?? []
      progress.passes = passes
      guard progress.nextPass < passes.count else { return nil }
      defer { progress.nextPass += 1 }
      return passes[progress.nextPass]
    }
  }
}

/// What a test observes of a scripted backend: its lifetime, each pass, and
/// the delivery of its transcript.
///
/// The library backend knows only this seam. The test support implements it
/// with the counters and the recorders of a test.
public protocol ScriptedBackendObserver: Sendable {
  /// A backend was made: a new one, a fork, or one over a replaced
  /// transcript.
  func backendMade()

  /// A backend was released.
  func backendReleased()

  /// A pass is about to play. The pass waits here for the model, if the
  /// observer owns a model lock.
  ///
  /// - Parameter prompt: The prompt the pass answers.
  /// - Returns: The turn that holds the model for the pass, or `nil` for
  ///   a pass that takes no model lock.
  /// - Throws: `CancellationError` when the task is cancelled while the
  ///   pass waits for the model.
  func passWillStart(prompt: String) async throws -> (any ScriptedPassTurn)?

  /// The transcript changed. The open update streams do not have the
  /// change yet.
  func transcriptWillDeliver()

  /// An update stream of the transcript ended. The backend still has it.
  func updateStreamEnded()
}

/// The hold of the model by one pass. The pass leaves the model for each
/// tool body and takes it again after the body.
public protocol ScriptedPassTurn: Sendable {
  /// Leaves the model before a tool body.
  func leave()

  /// Waits for the model after a tool body, and takes it.
  ///
  /// - Throws: `CancellationError` when the task is cancelled first.
  func takeAgain() async throws

  /// Ends the pass: leaves the model when the pass holds it.
  func end()
}

/// A resident model whose every session plays a ``ScriptedPlaybook``.
///
/// All four factories are written out on purpose, like
/// ``EchoLLMContainer``: the public default of
/// `makeSession(instructions:tools:)` DROPS `tools`, and a scripted
/// tool call needs them.
public struct ScriptedLLMContainer: LoadedLLMContainer {
  /// The counter of a model with no tokenizer: one token per character.
  public var tokenCounter: any TokenCounter { CharacterCountTokenCounter() }

  /// The playbook each session starts from. Each session gets a sibling of
  /// it.
  public let playbook: ScriptedPlaybook

  /// The observer of each backend of this model, or `nil` to observe
  /// nothing.
  public let observer: (any ScriptedBackendObserver)?

  /// Creates a container whose every session plays `playbook`.
  ///
  /// - Parameters:
  ///   - playbook: The playbook of each session.
  ///   - observer: The observer of each backend, or `nil` (the default)
  ///     to observe nothing.
  public init(playbook: ScriptedPlaybook, observer: (any ScriptedBackendObserver)? = nil) {
    self.playbook = playbook
    self.observer = observer
  }

  /// Makes a scripted backend that plays a sibling of the playbook.
  ///
  /// - Parameter instructions: The session instructions, or `nil` for none.
  /// - Returns: A new scripted backend with no tools.
  public func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
    makeBackend(tools: [], instructions: instructions)
  }

  /// Makes a scripted backend that plays a sibling of the playbook.
  ///
  /// - Parameters:
  ///   - instructions: The session instructions, or `nil` for none.
  ///   - tools: The tools that the played tool calls reach.
  /// - Returns: A new scripted backend.
  public func makeSession(
    instructions: String?, tools: [any Tool]
  ) -> any LanguageModelSessionBackend {
    makeBackend(tools: tools, instructions: instructions)
  }

  /// Makes a scripted backend that starts from the entries of `transcript`.
  ///
  /// - Parameter transcript: The transcript of the restored session.
  /// - Returns: A new scripted backend with no tools.
  public func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
    makeBackend(tools: [], seededEntries: Array(transcript))
  }

  /// Makes a scripted backend that starts from the entries of `transcript`.
  ///
  /// - Parameters:
  ///   - transcript: The transcript of the restored session.
  ///   - tools: The tools that the played tool calls reach.
  /// - Returns: A new scripted backend.
  public func makeSession(
    transcript: Transcript, tools: [any Tool]
  ) -> any LanguageModelSessionBackend {
    makeBackend(tools: tools, seededEntries: Array(transcript))
  }

  /// Makes one backend of this container: a sibling of the playbook and
  /// this observer.
  ///
  /// - Parameters:
  ///   - tools: The tools of the session.
  ///   - instructions: The session instructions, or `nil` for none.
  ///   - seededEntries: The transcript a restored session starts from,
  ///     or empty for a fresh session.
  /// - Returns: The backend.
  private func makeBackend(
    tools: [any Tool], instructions: String? = nil, seededEntries: [Transcript.Entry] = []
  ) -> any LanguageModelSessionBackend {
    ScriptedSessionBackend.makeSibling(
      of: playbook,
      tools: tools,
      instructions: instructions,
      seededEntries: seededEntries,
      observer: observer)
  }
}

/// The wait of a ``ScriptedPassStep/gate(path:)`` step.
enum ScriptedGate {
  /// The time between two looks for a file that does not exist yet. A file
  /// that is not there has no event to wait on, thus the wait looks again.
  private static let lookInterval = Duration.milliseconds(lookIntervalMilliseconds)

  /// The length of ``lookInterval``, in milliseconds.
  private static let lookIntervalMilliseconds = 25

  /// Waits until the file at `path` exists, or until one byte can be read
  /// from the named pipe at `path`.
  ///
  /// - Parameter path: The path of the file or of the named pipe.
  /// - Throws: `CancellationError` when the task is cancelled while the
  ///   file does not exist.
  static func wait(atPath path: String) async throws {
    while true {
      try Task.checkCancellation()
      var info = stat()
      if stat(path, &info) == 0 {
        if (info.st_mode & S_IFMT) == S_IFIFO {
          await StubChunkGate(path: path).waitForNextChunk()
        }
        return
      }
      try await Task.sleep(for: lookInterval)
    }
  }
}

import Foundation
import FoundationModels
import FoundationModelsACPAgent
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

// MARK: - The scripted-model seam
//
// The injectable `ModelLoader` every tier-2 test drives: no MLX, no
// download, no network, no Apple-silicon gate. It runs in CI at every
// commit.
//
// The steps, the backend and the container of the scripted model stand in
// the library, next to `EchoModel`: the `acp-agent` stub path plays the
// same steps. This file holds what only a test needs: the recorder of the
// prompts, the hooks of the transcript delivery, and the observer that
// connects them to the backend.
//
//   StubModelLoader (ModelLoader) -> ScriptedLLMContainer
//     -> ScriptedSessionBackend (LanguageModelSessionBackend)

/// Records every model prompt the scripted backend receives, so a
/// harness test asserts what the model was given.
public actor PromptRecorder {
  /// The recorded prompts, in arrival order.
  public private(set) var prompts: [String] = []

  /// Creates a recorder that has recorded nothing.
  public init() {}

  /// Records one prompt.
  ///
  /// - Parameter prompt: The prompt the backend received.
  public func record(prompt: String) {
    prompts.append(prompt)
  }
}

/// Records the reasoning effort level that the Router session states before
/// each submission attempt (D218), so a harness test asserts the level of
/// each turn of the model.
public final class ReasoningEffortRecorder: Sendable {
  /// The stated levels, in arrival order. `nil` is a submission with no
  /// level.
  private let stated = Mutex<[String?]>([])

  /// Creates a recorder that has recorded nothing.
  public init() {}

  /// The stated levels, in arrival order.
  public var levels: [String?] {
    stated.withLock { $0 }
  }

  /// Records one stated level.
  ///
  /// - Parameter level: The level of the session, or `nil` for no level.
  func record(_ level: String?) {
    stated.withLock { $0.append(level) }
  }
}

/// Two points in the delivery of a scripted transcript where a test can hold
/// the backend (``ScriptedSessionBackend/init(script:tools:instructions:seededEntries:recorder:passCounter:deliveryHooks:lifetimes:)``).
///
/// A test uses them to put a cancel of an update reader at an exact point
/// of a transcript change, with no dependency on timing. A backend that no
/// test changes has hooks that do nothing.
public struct TranscriptDeliveryHooks: Sendable {
  /// Runs after each change of the transcript, before the open
  /// ``ScriptedSessionBackend/transcriptUpdates()`` streams get the
  /// changed entries.
  public var beforeDelivery: @Sendable () -> Void

  /// Runs when a ``ScriptedSessionBackend/transcriptUpdates()`` stream
  /// ends, before the backend forgets the stream.
  public var beforeObserverRemoval: @Sendable () -> Void

  /// Makes hooks.
  ///
  /// - Parameters:
  ///   - beforeDelivery: The hook before each delivery. It does nothing
  ///     by default.
  ///   - beforeObserverRemoval: The hook before each removal of an
  ///     update stream. It does nothing by default.
  public init(
    beforeDelivery: @escaping @Sendable () -> Void = {},
    beforeObserverRemoval: @escaping @Sendable () -> Void = {}
  ) {
    self.beforeDelivery = beforeDelivery
    self.beforeObserverRemoval = beforeObserverRemoval
  }
}

/// The observer of a test: it records the prompts, owns the model lock of a
/// pass counter, counts the alive backends, and runs the delivery hooks.
/// Each part is optional.
struct ScriptedTestObserver: ScriptedBackendObserver {
  /// The recorder each received prompt goes to, or `nil`.
  let recorder: PromptRecorder?

  /// The counter of the passes and the owner of their model lock, or
  /// `nil` to count nothing and to play each call directly.
  let passCounter: ScriptedPassCounter?

  /// The count of the alive backends, or `nil`.
  let lifetimes: BackendLifetimes?

  /// The test hooks of the transcript delivery.
  let deliveryHooks: TranscriptDeliveryHooks

  /// The recorder of the reasoning effort level of each submission, or
  /// `nil`.
  var effortRecorder: ReasoningEffortRecorder?

  func backendMade() {
    lifetimes?.backendMade()
  }

  func backendReleased() {
    lifetimes?.backendReleased()
  }

  func passWillStart(prompt: String) async throws -> (any ScriptedPassTurn)? {
    let turn = try await passCounter?.startPass()
    await recorder?.record(prompt: prompt)
    return turn
  }

  func transcriptWillDeliver() {
    deliveryHooks.beforeDelivery()
  }

  func updateStreamEnded() {
    deliveryHooks.beforeObserverRemoval()
  }

  func reasoningEffortWillApply(_ level: String?) {
    effortRecorder?.record(level)
  }
}

extension ScriptedLLMContainer {
  /// Creates a container of a model with reasoning effort levels (D218),
  /// whose every session plays `script` from the start at each call.
  ///
  /// - Parameters:
  ///   - script: The script every session plays.
  ///   - reasoningEffortLevels: The levels of the scripted model.
  ///   - effortRecorder: The recorder of the level of each submission, or
  ///     `nil` (the default) to record nothing.
  public init(
    script: [ScriptedPassStep], reasoningEffortLevels: ReasoningEffortLevels,
    effortRecorder: ReasoningEffortRecorder? = nil
  ) {
    var observer = ScriptedTestObserver(
      recorder: nil, passCounter: nil, lifetimes: nil, deliveryHooks: TranscriptDeliveryHooks())
    observer.effortRecorder = effortRecorder
    self.init(
      playbook: .everyPass(script), observer: observer,
      reasoningEffortLevels: reasoningEffortLevels)
  }

  /// Creates a container whose every session plays `script` from the start
  /// at each call.
  ///
  /// - Parameters:
  ///   - script: The script every session plays.
  ///   - recorder: The recorder each session's prompts go to, or `nil`
  ///     (the default) to record nothing.
  ///   - passCounter: The counter of the passes of this model, or `nil`
  ///     (the default). A container with a counter is the queued scripted
  ///     model: each pass of its backends takes the model lock of the
  ///     counter.
  ///   - lifetimes: The count of the alive backends, or `nil` (the
  ///     default) to count nothing.
  public init(
    script: [ScriptedPassStep], recorder: PromptRecorder? = nil,
    passCounter: ScriptedPassCounter? = nil, lifetimes: BackendLifetimes? = nil
  ) {
    self.init(
      playbook: .everyPass(script),
      observer: ScriptedTestObserver(
        recorder: recorder, passCounter: passCounter, lifetimes: lifetimes,
        deliveryHooks: TranscriptDeliveryHooks()))
  }
}

extension ScriptedSessionBackend {
  /// Creates a backend that plays `script` from the start at each call,
  /// against `tools`.
  ///
  /// - Parameters:
  ///   - script: The steps to play, in order.
  ///   - tools: The tools `toolCall` steps invoke.
  ///   - deliveryHooks: The test hooks of the transcript delivery.
  public convenience init(
    script: [ScriptedPassStep], tools: [any Tool], deliveryHooks: TranscriptDeliveryHooks
  ) {
    self.init(
      playbook: .everyPass(script), tools: tools,
      observer: ScriptedTestObserver(
        recorder: nil, passCounter: nil, lifetimes: nil, deliveryHooks: deliveryHooks))
  }
}

/// Makes a loader whose LLM containers play `script`.
///
/// It reuses ``StubModelLoader`` — the injectable seam the stub profile
/// fixtures already have — so a scripted test downloads nothing and
/// loads nothing.
///
/// - Parameters:
///   - script: The steps every session plays.
///   - recorder: The recorder each received prompt goes to, or `nil`
///     to record nothing.
///   - lifetimes: The count of the alive backends of each container, or
///     `nil` to count nothing.
/// - Returns: The loader to inject.
public func makeScriptedModelLoader(
  script: [ScriptedPassStep], recorder: PromptRecorder? = nil, lifetimes: BackendLifetimes? = nil
) -> StubModelLoader {
  var loader = StubModelLoader()
  loader.makeLLMContainer = { _ in
    ScriptedLLMContainer(script: script, recorder: recorder, lifetimes: lifetimes)
  }
  return loader
}

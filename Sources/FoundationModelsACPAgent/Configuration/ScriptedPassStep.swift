import FoundationModels
import Synchronization

// MARK: - The steps of a scripted pass
//
// One vocabulary of steps, played by one backend (``ScriptedSessionBackend``).
// Two callers build on it:
//
// - The in-process test support, which gives a script of steps in code.
// - The `ACP_AGENT_STUB_SCRIPT` stub path of the `acp-agent` binary, which
//   reads the same steps from a JSON file (``ScriptedStubScript``).

/// One step of a scripted pass.
public enum ScriptedPassStep: Sendable, Equatable {
  /// Streams `text` as one delta.
  case textDelta(String)

  /// Adds `text` to the `.reasoning` entry of the pass. The first
  /// reasoning step of a pass makes that entry, and each reasoning step
  /// after it makes the text of the same entry longer. A proof that
  /// must show a call in flight to Router's repetition watch plays its
  /// reasoning with this step (task ^k51h6bb).
  case reasoning(String)

  /// Invokes the handed tool named `name` with the fixed
  /// `argumentsJSON`.
  case toolCall(name: String, argumentsJSON: String)

  /// Asks the user one form question with the text `message`, and waits
  /// for the answer. The form has one required text field named `answer`.
  ///
  /// The question is a real question of the session (``ScriptedElicitation``).
  /// The answer text is the output of the call, and the pass goes on with
  /// its next step. A decline or a cancel ends the pass with a clear text.
  case elicit(message: String)

  /// Throws the real SDK error `failure` names, so a stop-reason test
  /// drives the prompt owner's error mapping to a stop reason.
  case fail(ScriptedFailure)

  /// Suspends until the pass's task is cancelled, then throws
  /// `CancellationError`. A cancellation test holds the prompt open with
  /// this step and cancels it from the client end.
  case hold

  /// Suspends until the test calls ``ScriptedHold/release()`` on the
  /// hold, and then plays the next step. When the pass's task is
  /// cancelled first, it throws `CancellationError`, as ``hold`` does.
  case holdUntilReleased(ScriptedHold)

  /// Suspends until the file at `path` exists, or until one byte can be
  /// read from the named pipe at `path`. Then it plays the next step.
  ///
  /// A process test uses it to stop a run in the middle: the test makes
  /// the file, or writes one byte to the pipe, when it is ready. It is
  /// the gate of ``StubChunkGate``, for a step of a script.
  case gate(path: String)

  /// Writes `text` to the file at `path`, and plays no model output.
  ///
  /// A proof uses it to act BETWEEN two model steps, which is the only
  /// place a test can act inside a pass: the wire carries a played call
  /// when the pass's transcript diff goes out, thus nothing of a call is
  /// observable while the next call runs. The file may be a named pipe,
  /// and a write to one releases a run the step before it is holding.
  case writeFile(path: String, text: String)

  /// Plays `steps` in place of this step when the prompt of the pass
  /// contains `marker`, and plays nothing when it does not. An
  /// ``endPass`` in `steps` ends the whole pass.
  ///
  /// Each pass plays the same script. A proof uses this step to give the
  /// passes of one script different plays: each caller prompt carries its
  /// own marker, and an answer that mail starts carries no marker.
  indirect case onPrompt(containing: String, play: [ScriptedPassStep])

  /// Ends the pass. Steps after this one are never emitted.
  case endPass
}

/// The SDK failure a ``ScriptedPassStep/fail(_:)`` step throws.
///
/// The cases are `Equatable` markers; ``error`` makes the real
/// `LanguageModelError` value — the macOS 27 vocabulary the prompt
/// classifier reads — from the public payload initializers.
public enum ScriptedFailure: Sendable, Equatable {
  /// The context size the scripted overflow reports. The value only
  /// satisfies the payload initializer.
  private static let scriptedContextSize = 4096

  /// The token count the scripted overflow reports; larger than
  /// ``scriptedContextSize``, as a real overflow is.
  private static let scriptedTokenCount = 8192

  /// The guardrail refusal, which maps to the `refusal` stop reason.
  case guardrailViolation

  /// The context overflow, which maps to the `max_tokens` stop reason.
  case exceededContextWindow

  /// The real SDK error this failure throws.
  public var error: any Error {
    switch self {
    case .guardrailViolation:
      LanguageModelError.guardrailViolation(
        .init(debugDescription: "scripted guardrail refusal"))
    case .exceededContextWindow:
      LanguageModelError.contextSizeExceeded(
        .init(
          contextSize: Self.scriptedContextSize,
          tokenCount: Self.scriptedTokenCount,
          debugDescription: "scripted context overflow"))
    }
  }
}

/// The failure of a scripted step.
public enum ScriptedModelError: Error, Equatable {
  /// A `toolCall` step named a tool the session was not handed. The
  /// pass fails loudly instead of passing while measuring nothing.
  case unknownTool(String)
}

/// A hold that a scripted pass waits on until the test calls ``release()``.
///
/// The wait also ends when the task of the pass is cancelled. Then it throws
/// `CancellationError`. The wait is event-driven: a continuation, never a
/// timer. After ``release()``, each wait ends at once.
public final class ScriptedHold: Sendable, Equatable {
  /// The state of a hold: the passes that wait, or released.
  private enum State {
    /// The hold holds. The key of a waiter is its token.
    case holding(waiters: [Int: CheckedContinuation<Void, any Error>], nextToken: Int)

    /// The test called ``ScriptedHold/release()``.
    case released
  }

  /// The state, guarded because a wait, a cancel and the release can
  /// come from different tasks.
  private let state = Mutex(State.holding(waiters: [:], nextToken: 0))

  /// Creates a hold that holds.
  public init() {}

  /// Two holds are equal only when they are the same hold.
  ///
  /// - Parameters:
  ///   - lhs: A hold.
  ///   - rhs: Another hold.
  /// - Returns: `true` when `lhs` and `rhs` are the same object.
  public static func == (lhs: ScriptedHold, rhs: ScriptedHold) -> Bool {
    lhs === rhs
  }

  /// Ends each wait on this hold, and each later wait at once.
  public func release() {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
      guard case .holding(let waiters, _) = state else { return [] }
      state = .released
      return Array(waiters.values)
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  /// Waits until the test calls ``release()``, or until the task is
  /// cancelled.
  ///
  /// - Throws: `CancellationError` when the task is cancelled first.
  func waitForRelease() async throws {
    let token = state.withLock { state -> Int? in
      guard case .holding(let waiters, let nextToken) = state else { return nil }
      state = .holding(waiters: waiters, nextToken: nextToken + 1)
      return nextToken
    }
    guard let token else { return }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        admit(continuation, token: token)
      }
    } onCancel: {
      removeWaiter(token: token)?.resume(throwing: CancellationError())
    }
  }

  /// Keeps `continuation` as a waiter, or resumes it at once when the
  /// hold is released or the task is cancelled.
  ///
  /// The cancel flag is read under the lock. A cancel that comes before
  /// the waiter is kept thus finds no waiter, and this read sees the flag.
  ///
  /// - Parameters:
  ///   - continuation: The continuation of the waiting pass.
  ///   - token: The token of the waiter.
  private func admit(_ continuation: CheckedContinuation<Void, any Error>, token: Int) {
    let outcome = state.withLock { state -> Result<Void, any Error>? in
      guard case .holding(var waiters, let nextToken) = state else { return .success(()) }
      if Task.isCancelled {
        return .failure(CancellationError())
      }
      waiters[token] = continuation
      state = .holding(waiters: waiters, nextToken: nextToken)
      return nil
    }
    if let outcome {
      continuation.resume(with: outcome)
    }
  }

  /// Removes the waiter of `token`.
  ///
  /// - Parameter token: The token of the waiter.
  /// - Returns: The continuation of the waiter, or `nil` when the hold
  ///   has no waiter with that token.
  private func removeWaiter(token: Int) -> CheckedContinuation<Void, any Error>? {
    state.withLock { state in
      guard case .holding(var waiters, let nextToken) = state else { return nil }
      let removed = waiters.removeValue(forKey: token)
      state = .holding(waiters: waiters, nextToken: nextToken)
      return removed
    }
  }
}

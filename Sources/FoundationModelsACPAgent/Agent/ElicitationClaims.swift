import FoundationModelsACP
import FoundationModelsExtras
import Synchronization

extension ElicitationRequest {
  /// Whether a relay of Router sent this question up from a child. Only a relay sets the agent
  /// path. The question that the asking run posted has an empty path.
  var isRelayed: Bool {
    !agentPath.isEmpty
  }
}

/// The record of the questions that a session of a child holds. It stops the copy of a child
/// question, which Router sends up to each ancestor, from reaching the client a second time.
///
/// A question of a child run arrives at the relay of the child session as the original. The same
/// question, with the same elicitation id, arrives at the relay of each ancestor session as a
/// relayed copy. The client must get one request: the one of the child, under the id of the child.
/// The original and the copy are two events in two projectors, so the copy can come first. Thus a
/// relay that gets a copy does not send it. It waits here until the relay of the child claims the
/// id, and then it drops the copy.
///
/// A copy that no claim can reach would wait for ever. The host releases the copies of a session
/// when the child of that session got no session of its own here (``release(owner:)``). Then the
/// relay of that session sends the copy as a question of its own session. A release holds for the
/// later copies of that session too, because the question of the child that has no session can
/// come at any time. A client then can get the request of a healthy child twice, and never loses
/// a question.
///
/// A class, because the agent shares one record between the relays of all its sessions. A `Mutex`
/// guards the state.
final class ElicitationClaims: Sendable {
  /// How a wait for the claim of a question ended.
  enum CopyVerdict: Sendable, Equatable {
    /// The relay of a child claimed the question. The copy is not sent.
    case claimed

    /// The host released the copy. The relay sends it as a question of its own session.
    case released

    /// The relay ended the copy, because Router ended the question. The copy is not sent.
    case withdrawn
  }

  /// One relay that waits for the claim of a question.
  private struct Waiter {
    /// The session of the relay.
    let owner: SessionId

    /// The elicitation id of the question.
    let elicitationId: String

    /// Resumes the relay.
    let continuation: CheckedContinuation<CopyVerdict, Never>
  }

  /// The state that the lock guards.
  private struct State {
    /// The ids of the questions that a relay of a child claimed. A claim stays after the question
    /// ended, so a copy that comes late finds it.
    var claimed = RecentIDSet<String>(limit: ElicitationClaims.claimedLimit)

    /// The relays that wait, in the order of their calls.
    var waiters: [Waiter] = []

    /// The sessions whose copies the host released.
    var releasedOwners: Set<SessionId> = []
  }

  /// The most claims that the record keeps. A long session holds a bounded number of ids.
  static let claimedLimit = 4096

  /// The state, under its lock.
  private let state = Mutex(State())

  /// Makes an empty record.
  init() {}

  /// Records that the relay of a session holds the original of a question. Each relay that waits
  /// for this question resumes with ``CopyVerdict/claimed``.
  ///
  /// - Parameter elicitationId: The elicitation id of the question.
  func claim(_ elicitationId: String) {
    let resumed = state.withLock { state -> [Waiter] in
      state.claimed.insert(elicitationId)
      return Self.take(from: &state) { $0.elicitationId == elicitationId }
    }
    resume(resumed, with: .claimed)
  }

  /// Waits until a relay of a child claims the question. It returns at once for a question that
  /// is claimed already.
  ///
  /// - Parameters:
  ///   - elicitationId: The elicitation id of the copy.
  ///   - owner: The session of the relay that holds the copy.
  /// - Returns: How the wait ended.
  func awaitClaim(of elicitationId: String, for owner: SessionId) async -> CopyVerdict {
    await withCheckedContinuation { continuation in
      let verdict = state.withLock { state -> CopyVerdict? in
        if state.claimed.contains(elicitationId) {
          return .claimed
        }
        if state.releasedOwners.contains(owner) {
          return .released
        }
        state.waiters.append(
          Waiter(owner: owner, elicitationId: elicitationId, continuation: continuation))
        return nil
      }
      if let verdict {
        continuation.resume(returning: verdict)
      }
    }
  }

  /// Ends the wait of one copy: Router ended the question.
  ///
  /// - Parameters:
  ///   - elicitationId: The elicitation id of the copy.
  ///   - owner: The session of the relay that holds the copy.
  func withdraw(_ elicitationId: String, owner: SessionId) {
    let resumed = state.withLock { state in
      Self.take(from: &state) { $0.owner == owner && $0.elicitationId == elicitationId }
    }
    resume(resumed, with: .withdrawn)
  }

  /// Ends each wait of a session: its feed ended.
  ///
  /// - Parameter owner: The session of the relay.
  func withdrawAll(owner: SessionId) {
    let resumed = state.withLock { state in Self.take(from: &state) { $0.owner == owner } }
    resume(resumed, with: .withdrawn)
  }

  /// Releases each copy that a session holds, and each later copy of the session. The host calls
  /// it when a child of the session got no session here, so no relay of a child can claim the
  /// question of that child.
  ///
  /// - Parameter owner: The session of the relays that wait.
  func release(owner: SessionId) {
    let resumed = state.withLock { state -> [Waiter] in
      state.releasedOwners.insert(owner)
      return Self.take(from: &state) { $0.owner == owner }
    }
    resume(resumed, with: .released)
  }

  /// Takes the waiters that match out of the state.
  ///
  /// - Parameters:
  ///   - state: The state.
  ///   - matches: Tells if a waiter is taken.
  /// - Returns: The waiters that left the state.
  private static func take(from state: inout State, where matches: (Waiter) -> Bool) -> [Waiter] {
    let taken = state.waiters.filter(matches)
    state.waiters.removeAll(where: matches)
    return taken
  }

  /// Resumes waiters, outside the lock.
  ///
  /// - Parameters:
  ///   - waiters: The waiters.
  ///   - verdict: How their wait ended.
  private func resume(_ waiters: [Waiter], with verdict: CopyVerdict) {
    for waiter in waiters {
      waiter.continuation.resume(returning: verdict)
    }
  }
}

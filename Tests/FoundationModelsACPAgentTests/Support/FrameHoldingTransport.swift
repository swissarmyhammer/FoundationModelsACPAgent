import Foundation
import FoundationModelsACP
import Synchronization

/// One end of the wire that keeps back the first frame that holds a marker, until the test
/// releases it. Each other frame goes through at once. A transport that starts disarmed keeps no
/// frame until the test arms it, so a connection can carry frames with the marker before the step
/// that the test stops.
///
/// The writer of the kept frame waits in ``write(_:)``. So a test can stop a request of the agent
/// at a known step, and do work while the request waits there. The transport writes frames from
/// other writers while it keeps the one frame, as the `ACPTransport` contract lets two writes
/// overlap.
final class FrameHoldingTransport: ACPTransport {
  /// Where the hold is.
  private enum Phase {
    /// The test did not arm the transport yet. Each frame goes through.
    case disarmed

    /// No frame with the marker came since the transport was armed.
    case armed

    /// The transport keeps a frame. The value resumes its writer.
    case holding(CheckedContinuation<Void, Never>)

    /// The test released the hold. Each frame goes through.
    case released
  }

  /// The state that the lock guards.
  private struct State {
    /// Where the hold is.
    var phase: Phase

    /// The callers of ``waitUntilHolding()`` that wait for the kept frame.
    var watchers: [CheckedContinuation<Void, Never>] = []
  }

  /// The wrapped end.
  private let base: any ACPTransport

  /// The text that marks the frame to keep.
  private let marker: String

  /// The state, under its lock.
  private let state: Mutex<State>

  /// The incoming chunks of the wrapped end.
  var bytes: AsyncThrowingStream<Data, any Error> { base.bytes }

  /// The connection info of the wrapped end.
  var connectionInfo: ACPConnectionInfo? { base.connectionInfo }

  /// Wraps an end of the wire.
  ///
  /// - Parameters:
  ///   - base: The end to wrap.
  ///   - marker: The text that marks the frame to keep. The first frame that holds it waits.
  ///   - armed: Whether the transport keeps the first marked frame from the start. With `false`,
  ///     it keeps the first marked frame after ``arm()``.
  init(
    wrapping base: any ACPTransport, holdingFirstFrameContaining marker: String,
    armed: Bool = true
  ) {
    self.base = base
    self.marker = marker
    self.state = Mutex(State(phase: armed ? .armed : .disarmed))
  }

  /// Arms a disarmed transport: the next frame that holds the marker waits. A transport that is
  /// armed, keeps a frame, or was released does not change.
  func arm() {
    state.withLock { state in
      if case .disarmed = state.phase {
        state.phase = .armed
      }
    }
  }

  /// Writes one frame. The first frame that holds the marker waits until ``release()``.
  ///
  /// - Parameter data: The framed bytes.
  /// - Throws: Whatever the wrapped end throws.
  func write(_ data: Data) async throws {
    if String(decoding: data, as: UTF8.self).contains(marker) {
      await waitIfFirstMarkedFrame()
    }
    try await base.write(data)
  }

  /// Waits until the transport keeps the marked frame. Returns at once when it keeps it now, or
  /// when the test released the hold.
  func waitUntilHolding() async {
    await withCheckedContinuation { (watcher: CheckedContinuation<Void, Never>) in
      let waits = state.withLock { state -> Bool in
        switch state.phase {
        case .disarmed, .armed:
          state.watchers.append(watcher)
          return true
        case .holding, .released:
          return false
        }
      }
      if !waits {
        watcher.resume()
      }
    }
  }

  /// Lets the kept frame go, and each later frame. A release before the marked frame comes means
  /// that no frame waits, and each caller of ``waitUntilHolding()`` resumes.
  func release() {
    let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      defer {
        state.phase = .released
        state.watchers = []
      }
      guard case .holding(let writer) = state.phase else {
        return state.watchers
      }
      return [writer]
    }
    for continuation in waiting {
      continuation.resume()
    }
  }

  /// Keeps the caller when its frame is the first marked frame. Else returns at once.
  private func waitIfFirstMarkedFrame() async {
    await withCheckedContinuation { (writer: CheckedContinuation<Void, Never>) in
      let watchers = state.withLock { state -> [CheckedContinuation<Void, Never>]? in
        guard case .armed = state.phase else {
          return nil
        }
        state.phase = .holding(writer)
        defer { state.watchers = [] }
        return state.watchers
      }
      guard let watchers else {
        writer.resume()
        return
      }
      for watcher in watchers {
        watcher.resume()
      }
    }
  }
}

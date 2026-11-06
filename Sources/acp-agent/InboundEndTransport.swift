import Foundation
import FoundationModelsACP

/// A transport that hands another transport's inbound chunks on
/// unchanged, and reports when that inbound stream ends.
///
/// `acp` mode needs the report. A stdio agent has no teardown
/// handshake: the client closes stdin, the agent's read of
/// stdin ends, and the process is finished. `AgentSideConnection`
/// consumes the inbound stream itself. Its `closed` value comes only
/// after each inbound handler ended, so a prompt that still runs holds
/// that value back. The end of stdin itself is observable only in front
/// of the connection — here.
///
/// This wrapper reads nothing and records nothing. It forwards, so the
/// connection behind it reads the same chunks, in the same order, that
/// it reads with no wrapper at all, and it adds one wait
/// (``waitForInboundEnd()``) and one gate (``releaseInbound()``).
///
/// **The gate.** `AgentSideConnection` starts its read loop in its
/// initializer and sets the agent role after the initializer built the
/// agent. A client that wrote `initialize` while the agent was loading
/// has its frame in the pipe already, so the loop can serve it before
/// the role is set, and the client gets `methodNotFound`. A caller that
/// passes `holdingInbound: true` makes the wrapper forward nothing
/// until it calls ``releaseInbound()`` after the connection is built.
final class InboundEndTransport: ACPTransport, Sendable {
  /// The inbound chunks, forwarded from the wrapped transport.
  let bytes: AsyncThrowingStream<Data, any Error>

  /// The wrapped transport, which owns the outbound direction.
  private let upstream: any ACPTransport

  /// A stream that yields no element and finishes when the inbound
  /// stream ends. ``waitForInboundEnd()`` parks on it.
  private let inboundEnd: AsyncStream<Never>

  /// The gate. It yields once when ``releaseInbound()`` runs, and it
  /// finishes when the forwarded stream is torn down.
  private let gate: AsyncStream<Void>.Continuation

  /// Wraps `upstream` and starts forwarding its inbound chunks.
  ///
  /// - Parameters:
  ///   - upstream: The transport to wrap.
  ///   - holdingInbound: When `true`, no chunk is forwarded before
  ///     ``releaseInbound()``. The default forwards at once.
  init(wrapping upstream: any ACPTransport, holdingInbound: Bool = false) {
    self.upstream = upstream
    let (opened, openedContinuation) = AsyncStream<Void>.makeStream()
    gate = openedContinuation
    if !holdingInbound { openedContinuation.yield() }
    let (forwarded, forwardedContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let (end, endContinuation) = AsyncStream<Never>.makeStream()
    bytes = forwarded
    inboundEnd = end
    let forwarding = Task {
      for await _ in opened { break }
      do {
        for try await chunk in upstream.bytes {
          forwardedContinuation.yield(chunk)
        }
        forwardedContinuation.finish()
      } catch {
        forwardedContinuation.finish(throwing: error)
      }
      endContinuation.finish()
    }
    // A consumer that tears the forwarded stream down stops the
    // wrapped read as well, and releases the wait with it, so no
    // task is left suspended on a stream nobody drives.
    forwardedContinuation.onTermination = { _ in
      openedContinuation.finish()
      forwarding.cancel()
      endContinuation.finish()
    }
  }

  /// Opens the gate: the wrapper forwards the inbound chunks from now
  /// on, the chunks that came before included. A second call does
  /// nothing.
  func releaseInbound() {
    gate.yield()
  }

  /// Suspends until the inbound stream ends, and returns at once when
  /// it already has. For a stdio transport that end is stdin EOF.
  func waitForInboundEnd() async {
    for await _ in inboundEnd {}
  }

  /// Forwards one outgoing chunk to the wrapped transport.
  ///
  /// - Parameter data: The framed bytes to send.
  /// - Throws: Whatever the wrapped transport throws.
  func write(_ data: Data) async throws {
    try await upstream.write(data)
  }
}

import Foundation
import FoundationModelsACP

/// A transport that hands another transport's inbound chunks on
/// unchanged, and reports when that inbound stream ends.
///
/// `acp` mode needs the report. plan.md §17 gives a stdio agent no
/// teardown handshake: the client closes stdin, the agent's read of
/// stdin ends, and the process is finished. `AgentSideConnection`
/// consumes the inbound stream itself and tells its agent nothing about
/// the end, so the end is observable only in front of the connection —
/// here.
///
/// This wrapper reads nothing and records nothing. It forwards, so the
/// connection behind it reads the same chunks, in the same order, that
/// it reads with no wrapper at all, and it adds one wait
/// (``waitForInboundEnd()``) and nothing else.
final class InboundEndTransport: ACPTransport, Sendable {
    /// The inbound chunks, forwarded from the wrapped transport.
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The wrapped transport, which owns the outbound direction.
    private let upstream: any ACPTransport

    /// A stream that yields no element and finishes when the inbound
    /// stream ends. ``waitForInboundEnd()`` parks on it.
    private let inboundEnd: AsyncStream<Never>

    /// Wraps `upstream` and starts forwarding its inbound chunks.
    ///
    /// - Parameter upstream: The transport to wrap.
    init(wrapping upstream: any ACPTransport) {
        self.upstream = upstream
        let (forwarded, forwardedContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (end, endContinuation) = AsyncStream<Never>.makeStream()
        bytes = forwarded
        inboundEnd = end
        let forwarding = Task {
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
            forwarding.cancel()
            endContinuation.finish()
        }
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

import Foundation
import FoundationModelsACP

/// One end of the wire that keeps every framed line the peer sent, in
/// wire order, and hands the bytes on unchanged.
///
/// The ``UpdateCollector`` starts at the client's notification handler,
/// and the observable container starts further downstream again. Both
/// are therefore blind to the JSON-RPC responses the same wire carries.
/// An order claim that spans a response and a notification — plan.md
/// §8.1's "send the `{}` response first, then `user_message`" — is
/// observable only on the bytes, which is what this tap reads.
///
/// The tap wraps another `ACPTransport` instead of replacing it, so the
/// connection under test reads the same chunks, in the same order, that
/// it reads without the tap.
public final class WireTap: ACPTransport {
    /// The store of the received lines.
    private actor Store {
        /// The received lines, in wire order.
        private(set) var lines: [String] = []

        /// Appends one framed line.
        ///
        /// - Parameter line: The line the peer sent, without its
        ///   newline.
        func append(line: String) {
            lines.append(line)
        }
    }

    /// The incoming chunks, forwarded from the wrapped end.
    public let bytes: AsyncThrowingStream<Data, any Error>

    /// The wrapped end, which owns the outgoing direction.
    private let base: any ACPTransport

    /// The store the forwarding task fills.
    private let store: Store

    /// The forwarding task, ended by ``stop()``.
    private let forwarding: Task<Void, Never>

    /// Every framed line the peer sent, in wire order.
    public var lines: [String] {
        get async { await store.lines }
    }

    /// Wraps `base` and starts forwarding its incoming chunks.
    ///
    /// Each chunk is framed into lines and recorded before it is handed
    /// on, so the store is never behind the connection.
    ///
    /// - Parameter base: The end of the wire to tap.
    public init(tapping base: any ACPTransport) {
        let store = Store()
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        bytes = stream
        self.base = base
        self.store = store
        forwarding = Task {
            var framer = NDJSONFramer()
            do {
                for try await chunk in base.bytes {
                    for line in framer.append(chunk) {
                        await store.append(line: String(decoding: line, as: UTF8.self))
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Writes one outgoing chunk through the wrapped end.
    ///
    /// - Parameter data: The bytes to send, already framed.
    /// - Throws: Whatever the wrapped end throws.
    public func write(_ data: Data) async throws {
        try await base.write(data)
    }

    /// Ends the forwarding task. Nothing consumes the wrapped end after
    /// this call, so a closed harness leaves no suspended task behind.
    public func stop() {
        forwarding.cancel()
    }
}

import Foundation
import FoundationModelsACP
import Synchronization

/// One end of a wire made of real operating-system pipes: the inbound
/// direction is a descriptor read, and the outbound direction is a
/// descriptor write.
///
/// This is the shape `acp` mode runs on. `StdioTransport` binds that
/// shape to this process's standard input and standard output, and one
/// process has one of each, so a suite that must drive an agent over
/// real pipes in process cannot use it. ``HarnessWire/makeStdioPipes()``
/// pairs two of these instead (cli-plan.md §9).
///
/// Marked `@unchecked Sendable` because it stores `FileHandle` values,
/// which are not `Sendable`. Every mutation is serialized: the outbound
/// handle is reached only under ``output``'s lock, so two whole-frame
/// writes never interleave, and the inbound handle is read only by the
/// readability handler the initializer installs.
public final class PipeTransport: ACPTransport, @unchecked Sendable {
    /// The inbound chunks, read until end of file.
    public let bytes: AsyncThrowingStream<Data, any Error>

    /// The read end this transport receives on.
    private let input: FileHandle

    /// The write end this transport sends on, guarded so two whole-frame
    /// writes never interleave.
    private let output: Mutex<FileHandle>

    /// Wires one end over a read handle and a write handle.
    ///
    /// - Parameters:
    ///   - input: The read end. Its bytes surface on ``bytes``, which
    ///     finishes at end of file.
    ///   - output: The write end every ``write(_:)`` goes to.
    public init(reading input: FileHandle, writing output: FileHandle) {
        self.input = input
        self.output = Mutex(output)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        bytes = stream
        input.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(chunk)
        }
    }

    /// Writes one whole frame to the outbound end as one unit.
    ///
    /// - Parameter data: The framed bytes to send.
    /// - Throws: The write error the outbound handle reports.
    public func write(_ data: Data) async throws {
        try output.withLock { handle in
            try handle.write(contentsOf: data)
        }
    }

    /// Closes both handles, so the peer's read reaches end of file and
    /// this end delivers nothing more. Idempotent.
    public func close() {
        input.readabilityHandler = nil
        try? input.close()
        output.withLock { try? $0.close() }
    }
}

/// The transport pair one ``AgentClientHarness`` runs over
/// (cli-plan.md §4).
///
/// The CLI reaches the agent through an ACP connection in every mode,
/// and only the transport changes: `run` uses `InMemoryTransport.pair()`
/// in one process, and `acp` speaks ndJSON on stdin and stdout. A suite
/// that must prove the two modes answer alike drives the same harness
/// over ``makeInMemory()`` and then over ``makeStdioPipes()``.
public struct HarnessWire: Sendable {
    /// The end the client drives.
    public let clientEnd: any ACPTransport

    /// The end the agent serves.
    public let agentEnd: any ACPTransport

    /// Ends both directions of the wire.
    private let release: @Sendable () -> Void

    /// Makes a fresh in-process pair, the transport `run` mode and the
    /// Mac app use.
    ///
    /// - Returns: The two ends, with no pipe and no subprocess.
    public static func makeInMemory() -> HarnessWire {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        return HarnessWire(clientEnd: clientEnd, agentEnd: agentEnd) {
            clientEnd.close()
            agentEnd.close()
        }
    }

    /// Makes a fresh pair of ``PipeTransport`` ends over two operating
    /// system pipes: what the client writes the agent reads, and the
    /// other way round.
    ///
    /// - Returns: The two ends, over the descriptor machinery `acp` mode
    ///   runs on.
    public static func makeStdioPipes() -> HarnessWire {
        let toAgent = Pipe()
        let toClient = Pipe()
        let clientEnd = PipeTransport(
            reading: toClient.fileHandleForReading, writing: toAgent.fileHandleForWriting)
        let agentEnd = PipeTransport(
            reading: toAgent.fileHandleForReading, writing: toClient.fileHandleForWriting)
        return HarnessWire(clientEnd: clientEnd, agentEnd: agentEnd) {
            clientEnd.close()
            agentEnd.close()
        }
    }

    /// Wires the two ends and the release both of them need.
    ///
    /// - Parameters:
    ///   - clientEnd: The end the client drives.
    ///   - agentEnd: The end the agent serves.
    ///   - release: What ``close()`` runs.
    private init(
        clientEnd: any ACPTransport, agentEnd: any ACPTransport,
        release: @escaping @Sendable () -> Void
    ) {
        self.clientEnd = clientEnd
        self.agentEnd = agentEnd
        self.release = release
    }

    /// Ends both directions of the wire, and releases whatever the two
    /// ends hold.
    public func close() {
        release()
    }
}

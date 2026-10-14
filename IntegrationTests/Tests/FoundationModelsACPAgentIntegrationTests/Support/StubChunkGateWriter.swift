import Darwin
import Foundation

/// The write end of the chunk gate of the spawned stub model
/// (`ACP_AGENT_STUB_CHUNK_GATE`): a named pipe that the stub reads one byte
/// from before each chunk of its answer.
///
/// Each byte lets one chunk go. The close lets each later chunk go at once,
/// because the stub then reads the end of the pipe. Thus a test holds a
/// prompt open, and decides when it goes on, with no clock.
final class StubChunkGateWriter: Sendable {
    /// The write handle of the pipe.
    private let handle: FileHandle

    /// Makes a named pipe at `path`.
    ///
    /// - Parameter path: The path of the new pipe.
    /// - Throws: The `mkfifo` error.
    static func makePipe(at path: URL) throws {
        guard mkfifo(path.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Opens the write end of the pipe at `path`. The open blocks in the
    /// kernel until the stub opens the read end, that is, until the stub
    /// waits before its first chunk. It runs on a thread of its own, and
    /// not on the cooperative pool.
    ///
    /// - Parameter path: The path of the pipe.
    /// - Returns: The writer.
    /// - Throws: The open error.
    static func open(at path: URL) async throws -> StubChunkGateWriter {
        try await withCheckedThrowingContinuation { continuation in
            let opener = Thread {
                let descriptor = Darwin.open(path.path, O_WRONLY)
                guard descriptor >= 0 else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
                // A write after the stub ended fails with `EPIPE`, and raises no
                // `SIGPIPE`, which would end this whole test process.
                _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                continuation.resume(
                    returning: StubChunkGateWriter(
                        handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)))
            }
            opener.start()
        }
    }

    /// Wraps an open write handle.
    ///
    /// - Parameter handle: The write handle of the pipe.
    private init(handle: FileHandle) {
        self.handle = handle
    }

    /// Lets one chunk go.
    ///
    /// - Throws: The write error.
    func releaseOneChunk() throws {
        try handle.write(contentsOf: Data([0]))
    }

    /// Lets each later chunk go: the stub reads the end of the pipe.
    ///
    /// - Throws: The close error.
    func releaseAllChunks() throws {
        try handle.close()
    }
}

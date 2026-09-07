import Darwin
import Foundation

/// A stand-in for stderr: a pipe, the handle a ``TerminalRenderer`` draws
/// to, and the bytes that reached it.
///
/// A pipe, and not a file, because cli-plan.md §5.2 asks for exactly this
/// proof: give the renderer a pipe, tell it whether the pipe is a
/// terminal, and count the bytes. The terminal path then needs no person
/// and no pseudo-terminal.
///
/// The read end is non-blocking, so ``bytes()`` gives back what is on the
/// pipe now and returns at once when nothing is there. A blocking read of
/// an empty pipe would never return, and "nothing was drawn" is the
/// result half of these tests look for.
///
/// The capture must outlive every draw to its ``destination``. Both ends
/// close when the capture goes, and the descriptors are then another
/// file's.
final class TerminalCapture {
    /// The size of one read from the pipe, in bytes.
    ///
    /// A whole render is a few hundred bytes, so one read normally takes
    /// everything; the drain loop covers the rest.
    private static let readChunkSize = 4096

    /// The pipe the renderer draws into.
    private let pipe = Pipe()

    /// The handle to hand to ``TerminalRenderer/init(destination:isTerminal:)``.
    let destination: FileHandle

    /// Creates a capture over a fresh pipe whose read end never blocks.
    init() {
        destination = pipe.fileHandleForWriting
        let readDescriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(readDescriptor, F_GETFL)
        _ = fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// Every byte on the pipe now, in write order.
    ///
    /// - Returns: The bytes, empty when nothing was drawn.
    func bytes() -> Data {
        let readDescriptor = pipe.fileHandleForReading.fileDescriptor
        var captured = Data()
        var buffer = [UInt8](repeating: 0, count: Self.readChunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(readDescriptor, raw.baseAddress, Self.readChunkSize)
            }
            guard count > 0 else { return captured }
            captured.append(contentsOf: buffer[0..<count])
        }
    }

    /// ``bytes()`` decoded as UTF-8.
    ///
    /// - Returns: The captured text, empty when nothing was drawn.
    func text() -> String {
        String(decoding: bytes(), as: UTF8.self)
    }
}

import Darwin
import Foundation

/// The failure of a write to the answer descriptor.
struct AnswerWriteError: Error, CustomStringConvertible {
    /// The descriptor the failing write went to.
    let fileDescriptor: Int32

    /// The `errno` value the failing `write(2)` set.
    let errorCode: Int32

    var description: String {
        "the answer could not be written to file descriptor \(fileDescriptor): errno \(errorCode)"
    }
}

/// Where the agent text of one `run` turn goes: a file descriptor,
/// standard output by default (cli-plan.md §5.6).
///
/// **One chunk at a time.** The turn hands each `agent_message_chunk`
/// over as it arrives, and this writer puts it on the descriptor at
/// once. A local model is slow, so a person must see the answer grow. A
/// `write(2)` carries no user-space buffer, so the chunk is on the
/// descriptor when the call returns: that is the flush.
///
/// **Verbatim.** The writer adds no trailing newline, and it adds no
/// color, in a terminal and in a pipe alike. The output is data, and a
/// rule that changes with a terminal cannot be tested byte for byte. So
/// `acp-agent run "hi" > out.txt` gives a file whose bytes equal the
/// chunks joined, with nothing added and nothing removed.
///
/// **Nothing else.** Not a session id, not a token count, not a stop
/// reason. Those go to stderr.
///
/// This is not a ``CommandReport``. A report is one finished text a
/// reporting subcommand writes when it is done; an answer arrives in
/// parts over minutes, and a person must see it grow.
struct AnswerWriter {
    /// The descriptor each chunk goes to.
    let fileDescriptor: Int32

    /// Creates a writer over one descriptor.
    ///
    /// - Parameter fileDescriptor: The descriptor to write to. The
    ///   default is standard output, which is where a `run` answer
    ///   belongs.
    init(fileDescriptor: Int32 = STDOUT_FILENO) {
        self.fileDescriptor = fileDescriptor
    }

    /// Writes one chunk of the answer, and leaves it on the descriptor.
    ///
    /// - Parameter chunk: The text of one `agent_message_chunk`.
    /// - Throws: ``AnswerWriteError`` when the write fails.
    func receive(_ chunk: String) throws {
        try writeAll(Data(chunk.utf8))
    }

    /// Writes every byte of `bytes` to ``fileDescriptor``.
    ///
    /// A `write(2)` may take fewer bytes than it was offered, and a
    /// signal may interrupt it, so the loop offers what is left again
    /// until nothing is left.
    ///
    /// - Parameter bytes: The bytes to write.
    /// - Throws: ``AnswerWriteError`` when the write fails.
    private func writeAll(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fileDescriptor, base + written, buffer.count - written)
                guard count >= 0 else {
                    guard errno == EINTR else {
                        throw AnswerWriteError(
                            fileDescriptor: fileDescriptor, errorCode: errno)
                    }
                    continue
                }
                written += count
            }
        }
    }
}

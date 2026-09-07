import Foundation
import Testing

@testable import acp_agent

/// The stdout contract of `run` (cli-plan.md §5.6): the answer goes to
/// the descriptor verbatim, one chunk at a time.
///
/// The output is data. A rule that changes with a terminal cannot be
/// tested byte for byte, so the writer adds no trailing newline and no
/// color, in a terminal and in a pipe alike. These tests read the bytes,
/// and not the text, because only the bytes prove that.
struct AnswerWriterTests {
    // MARK: - Constants

    /// The chunks one turn hands over, as the card names them.
    private static let chunks = ["a", "b", "c"]

    /// What the descriptor must carry after ``chunks``: the chunks
    /// joined, with nothing added and nothing removed.
    private static let joinedChunks = "abc"

    // MARK: - The bytes on the descriptor

    /// Three chunks give exactly the three bytes. No newline follows
    /// them, and no escape sequence surrounds them: the captured bytes
    /// equal `abc` and nothing else.
    @Test func theChunksReachTheDescriptorVerbatim() throws {
        let capture = try AnswerCapture(label: "AnswerWriterTests-verbatim")

        for chunk in Self.chunks {
            try capture.writer.receive(chunk)
        }

        #expect(try capture.bytes() == Data(Self.joinedChunks.utf8))
    }

    /// A chunk is on the descriptor when ``AnswerWriter/receive(_:)``
    /// returns, and does not wait for the next chunk or for the end of
    /// the turn. A local model is slow, so a person must see the answer
    /// grow.
    @Test func eachChunkIsOnTheDescriptorBeforeTheNextOneIsWritten() throws {
        let capture = try AnswerCapture(label: "AnswerWriterTests-growing")
        let first = try #require(Self.chunks.first)

        try capture.writer.receive(first)

        #expect(try capture.bytes() == Data(first.utf8))
    }

    /// The writer a `run` builds with no descriptor writes to standard
    /// output, which is descriptor 1.
    @Test func theDefaultWriterTargetsStandardOutput() {
        #expect(AnswerWriter().fileDescriptor == STDOUT_FILENO)
    }
}

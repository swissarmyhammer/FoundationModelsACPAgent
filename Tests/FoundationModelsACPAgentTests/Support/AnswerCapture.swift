import Foundation
import FoundationModelsACPAgentTestSupport

@testable import acp_agent

/// A stand-in for stdout: an ``AnswerWriter`` over a throwaway file, and
/// the bytes that reached it.
///
/// The writer is the one `run` uses, over another descriptor, so a test
/// reads the exact bytes `acp-agent run "hi" > out.txt` would put in the
/// file — which is what this capture is.
///
/// A file, and not a pipe: a pipe holds only what its buffer holds, and
/// a writer whose reader waits for the end of the turn would block on a
/// long answer. A file takes every byte, and a read gives back what is
/// written so far, whether or not the turn has ended.
///
/// No test redirects the real descriptor 1: the suites run together, and
/// a redirect would take the output of every other suite with it.
///
/// A capture must outlive every write to its writer. The write handle
/// closes when the capture goes, and the descriptor is then another
/// file's.
final class AnswerCapture {
    /// The name of the file inside the throwaway directory.
    private static let fileName = "answer.txt"

    /// The file the writer writes to.
    private let url: URL

    /// The open write handle, which owns the descriptor the writer
    /// holds.
    private let handle: FileHandle

    /// The writer the answer goes to.
    let writer: AnswerWriter

    /// Creates a capture over a fresh file in a throwaway directory.
    ///
    /// - Parameter label: The directory label, so a leftover directory
    ///   says where it came from.
    /// - Throws: The file-creation or file-open error.
    init(label: String) throws {
        url = makeResolvedDirectory(label: label).appendingPathComponent(Self.fileName)
        try Data().write(to: url)
        handle = try FileHandle(forWritingTo: url)
        writer = AnswerWriter(fileDescriptor: handle.fileDescriptor)
    }

    /// Every byte the writer produced so far, in write order.
    ///
    /// - Returns: The bytes.
    /// - Throws: The read error.
    func bytes() throws -> Data {
        try Data(contentsOf: url)
    }

    /// ``bytes()`` decoded as UTF-8.
    ///
    /// - Returns: The captured text.
    /// - Throws: The read error.
    func text() throws -> String {
        try Self.text(at: url)
    }

    /// A test of whether the capture holds exactly `text` so far.
    ///
    /// The test holds the file location and not the capture, so another
    /// task may read what already arrived while the turn still runs, and
    /// the capture keeps its one owner. A case that must let a chunk
    /// arrive before it acts waits on this fact, and never on a delay.
    ///
    /// - Parameter text: The text the capture must hold.
    /// - Returns: The test. It reports `false` while the file holds
    ///   anything else, and while the file cannot be read.
    func holds(_ text: String) -> @Sendable () -> Bool {
        let url = url
        return { (try? Self.text(at: url)) == text }
    }

    /// The UTF-8 text of the capture file at `url`.
    ///
    /// - Parameter url: The capture file to read.
    /// - Returns: The text.
    /// - Throws: The read error.
    private static func text(at url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}

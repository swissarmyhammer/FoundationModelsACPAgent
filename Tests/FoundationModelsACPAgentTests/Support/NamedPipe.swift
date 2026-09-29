import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

/// A named pipe in a working directory, that a shell read of a test waits on.
///
/// A shell command `cat <name>` waits until a writer writes the pipe and
/// closes it. The test is that writer, thus the test decides when the shell
/// run settles.
enum NamedPipe {
    /// The permissions of each pipe: read and write for the owner.
    private static let permissions: mode_t = 0o600

    /// Makes a new working directory that holds one named pipe.
    ///
    /// - Parameters:
    ///   - name: The file name of the pipe.
    ///   - label: The directory label of the calling suite.
    /// - Returns: The directory.
    /// - Throws: When the named pipe cannot be made.
    static func makeDirectory(holding name: String, label: String) throws -> URL {
        let directory = makeResolvedDirectory(label: label)
        let pipe = directory.appendingPathComponent(name)
        try #require(mkfifo(pipe.path, permissions) == 0, "mkfifo failed with errno \(errno)")
        return directory
    }

    /// Writes `text` into the pipe at `pipe` after a reader opened it, and
    /// then closes the write end. The reader thus reads `text` and then the
    /// end of the stream.
    ///
    /// A write end that opens with `O_NONBLOCK` fails with `ENXIO` while no
    /// reader holds the pipe open. The poll opens it again until a reader
    /// holds it. Thus the text never goes into a pipe that no reader holds,
    /// where the close of the last writer would discard it.
    ///
    /// - Parameters:
    ///   - text: The text to write.
    ///   - pipe: The named pipe.
    /// - Throws: When no reader opens the pipe before the poll deadline, or
    ///   when the write fails.
    static func write(_ text: String, toPipeAt pipe: URL) async throws {
        var descriptor: Int32 = -1
        try await Poll.until("a reader opens \(pipe.lastPathComponent)") {
            descriptor = open(pipe.path, O_WRONLY | O_NONBLOCK)
            return descriptor >= 0
        }
        try #require(descriptor >= 0, "no reader opened \(pipe.path)")
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

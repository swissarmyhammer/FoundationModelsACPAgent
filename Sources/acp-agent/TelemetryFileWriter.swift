import Darwin
import Foundation
import FoundationModelsACP
import Synchronization

/// The one writer of the file of `acp --telemetry-file`: it appends each
/// record as one JSON object on one line.
///
/// The log handler, the tracer and the metrics factory of the file all write
/// through one writer, so the records of all three stand in one file, in the
/// order of their writes.
///
/// Each record is one whole line, written under a lock. Thus the line of one
/// thread never cuts into the line of another thread, at any size: the
/// `O_APPEND` flag alone makes no such promise for a write larger than
/// `PIPE_BUF`. The writer keeps no buffer, so a record is in the file when
/// ``write(_:)`` returns, and a process that crashes loses no record that it
/// wrote.
///
/// The descriptor has `O_CLOEXEC`, so a shell child of the agent does not
/// get it.
///
/// The lock is a `Mutex` and not an actor, because each caller is
/// synchronous: `LogHandler.log(event:)`, `Span.end(at:)` and each metric
/// handler method return before the record could wait for an actor.
final class TelemetryFileWriter: Sendable {
    /// Why the telemetry file cannot be opened.
    struct OpenError: Error, CustomStringConvertible {
        /// The path of the file.
        let path: String

        /// The `errno` value of the failed `open(2)`.
        let code: Int32

        /// The path and the system reason, for the usage error of the CLI.
        var description: String {
            "cannot open the telemetry file \(path): \(String(cString: strerror(code)))"
        }
    }

    /// The flags of `open(2)`: write only, make the file when it is absent,
    /// append each write to the end, and close the descriptor in a child
    /// process.
    private static let openFlags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC

    /// The permission bits of a new file: read and write for the owner, read
    /// for all others.
    private static let fileMode: mode_t = 0o644

    /// The bytes at the end of each record.
    private static let lineEnd = Data("\n".utf8)

    /// The text of a positive infinity, which JSON has no number for. The
    /// Extras tokens-per-second recorder divides by the model time, so a
    /// call with no model time records an infinity.
    private static let positiveInfinityText = "Infinity"

    /// The text of a negative infinity.
    private static let negativeInfinityText = "-Infinity"

    /// The text of a value that is not a number.
    private static let notANumberText = "NaN"

    /// The descriptor of the file, and whether a failed write was reported.
    private let state: Mutex<State>

    /// Opens `path` to append, and makes the file when it is absent.
    ///
    /// - Parameter path: The path of the telemetry file.
    /// - Throws: ``OpenError`` when `open(2)` fails, for example because the
    ///   directory is absent or the file is not writable.
    init(path: String) throws {
        let descriptor = open(path, Self.openFlags, Self.fileMode)
        guard descriptor >= 0 else {
            throw OpenError(path: path, code: errno)
        }
        state = Mutex(State(descriptor: descriptor))
    }

    deinit {
        state.withLock { state in
            _ = close(state.descriptor)
        }
    }

    /// Appends `record` as one line.
    ///
    /// A record that cannot be written is dropped, and the first such failure
    /// goes to stderr one time: the telemetry file must never stop the
    /// agent, and a log record about the failure would come back to this
    /// writer.
    ///
    /// - Parameter record: The JSON object of the record.
    func write(_ record: [String: JSONValue]) {
        let line: Data
        do {
            line = try Self.makeEncoder().encode(record) + Self.lineEnd
        } catch {
            state.withLock { $0.reportFailure("a record does not encode as JSON") }
            return
        }
        state.withLock { $0.append(line) }
    }

    /// Makes the encoder of one record: sorted keys, so each line has one
    /// stable order, and a text for each number that JSON cannot hold.
    ///
    /// - Returns: The encoder.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: positiveInfinityText, negativeInfinity: negativeInfinityText, nan: notANumberText)
        return encoder
    }

    /// The state under the lock of the writer.
    private struct State {
        /// The descriptor of the open file.
        let descriptor: Int32

        /// Whether a failed write already went to stderr.
        var hasReportedFailure = false

        /// Writes all bytes of `line`, and reports the first failure.
        ///
        /// - Parameter line: The encoded record and its line end.
        mutating func append(_ line: Data) {
            guard let failureCode = Self.writeWhole(line, to: descriptor) else { return }
            reportFailure(String(cString: strerror(failureCode)))
        }

        /// Writes `reason` to stderr, the first time only.
        ///
        /// - Parameter reason: Why the record was dropped.
        mutating func reportFailure(_ reason: String) {
            guard !hasReportedFailure else { return }
            hasReportedFailure = true
            FileHandle.standardError.write(Data("acp-agent: the telemetry file dropped a record: \(reason)\n".utf8))
        }

        /// Writes all bytes of `line` to `descriptor`, and writes again after
        /// a short write or an interrupted write.
        ///
        /// - Parameters:
        ///   - line: The bytes.
        ///   - descriptor: The descriptor of the file.
        /// - Returns: `nil` when all bytes are written, else the `errno` value
        ///   of the failed write.
        private static func writeWhole(_ line: Data, to descriptor: Int32) -> Int32? {
            line.withUnsafeBytes { buffer -> Int32? in
                guard let base = buffer.baseAddress else { return nil }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                    if written >= 0 {
                        offset += written
                    } else if errno != EINTR {
                        return errno
                    }
                }
                return nil
            }
        }
    }
}

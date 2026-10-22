import Darwin
import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import Synchronization

/// The one writer of the file of `acp --telemetry-file`: it appends each
/// record as one JSON object on one line, through the Extras `JSONLFile`.
///
/// The log handler, the tracer and the metrics factory of the file all write
/// through one writer, so the records of all three stand in one file, in the
/// order of their writes.
///
/// `JSONLFile` gives each record the rules of every JSON Lines file of the
/// package family: it opens the file to append, sends the whole line in one
/// `write(2)`, calls `fsync(2)` before it returns, and starts the line with a
/// `\n` when a crash left a torn line at the end of the file. Each record
/// opens the file with its own `O_APPEND` descriptor, so the line of one
/// thread never cuts into the line of another thread, and a process that
/// crashes loses no record that it wrote. The descriptor has `O_CLOEXEC`, so
/// a shell child of the agent does not get it.
///
/// Each line is the JSON of the record with sorted keys and slashes not
/// escaped, the format that the bench harness reads. A number that JSON
/// cannot hold writes as its text, see ``conforming(_:)``.
final class TelemetryFileWriter: Sendable {
    /// Why the telemetry file cannot be written.
    struct OpenError: Error, CustomStringConvertible {
        /// The path of the file.
        let path: String

        /// The `errno` value of the failed check.
        let code: Int32

        /// The path and the system reason, for the usage error of the CLI.
        var description: String {
            "cannot open the telemetry file \(path): \(String(cString: strerror(code)))"
        }
    }

    /// The access that the file needs: write.
    private static let fileAccess = W_OK

    /// The access that the folder of a new file needs: write, to make the
    /// file, and search, to reach it.
    private static let folderAccess = W_OK | X_OK

    /// The folder of a path that names no folder: the current folder.
    private static let currentFolder = "."

    /// The text of a positive infinity, which JSON has no number for. The
    /// Extras tokens-per-second recorder divides by the model time, so a
    /// call with no model time records an infinity.
    private static let positiveInfinityText = "Infinity"

    /// The text of a negative infinity.
    private static let negativeInfinityText = "-Infinity"

    /// The text of a value that is not a number.
    private static let notANumberText = "NaN"

    /// The file.
    private let file: JSONLFile

    /// Whether a dropped record already went to stderr.
    private let hasReportedFailure = Atomic<Bool>(false)

    /// Checks that the file at `path` can be written, and makes the writer.
    /// It opens nothing: the first record makes the file when it is absent.
    ///
    /// - Parameter path: The path of the telemetry file.
    /// - Throws: ``OpenError`` when the path names a folder, when the file is
    ///   not writable, or when the file is absent and its folder is absent
    ///   or not writable.
    init(path: String) throws {
        try Self.checkWritable(path)
        file = JSONLFile(url: URL(filePath: path))
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
        do {
            try file.append(record.mapValues(Self.conforming))
        } catch {
            reportFailure(error)
        }
    }

    /// Gives `value` with each number that JSON cannot hold, at any depth,
    /// replaced by its text: `Infinity`, `-Infinity` or `NaN`.
    ///
    /// - Parameter value: A JSON value of a record.
    /// - Returns: The value with finite numbers only.
    private static func conforming(_ value: JSONValue) -> JSONValue {
        switch value {
        case .number(let number) where number.isNaN:
            return .string(notANumberText)
        case .number(let number) where number.isInfinite:
            return .string(number > 0 ? positiveInfinityText : negativeInfinityText)
        case .array(let values):
            return .array(values.map(conforming))
        case .object(let members):
            return .object(members.mapValues(conforming))
        case .null, .bool, .number, .string:
            return value
        }
    }

    /// Writes the reason of a dropped record to stderr, the first time only.
    ///
    /// - Parameter error: Why the record was dropped.
    private func reportFailure(_ error: JSONLFileError) {
        guard hasReportedFailure.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
        else { return }
        FileHandle.standardError.write(Data("acp-agent: the telemetry file dropped a record: \(error)\n".utf8))
    }

    /// Checks that a record can make or append to the file at `path`: the
    /// path is not a folder, and the file is writable, or the file is absent
    /// and its folder is writable.
    ///
    /// - Parameter path: The path of the telemetry file.
    /// - Throws: ``OpenError`` with the `errno` value of the failed check.
    private static func checkWritable(_ path: String) throws(OpenError) {
        var status = stat()
        guard stat(path, &status) == 0 else {
            guard errno == ENOENT else {
                throw OpenError(path: path, code: errno)
            }
            try requireAccess(folder(of: path), folderAccess, for: path)
            return
        }
        guard status.st_mode & S_IFMT != S_IFDIR else {
            throw OpenError(path: path, code: EISDIR)
        }
        try requireAccess(path, fileAccess, for: path)
    }

    /// Checks `mode` access to `target` with `access(2)`.
    ///
    /// - Parameters:
    ///   - target: The file or the folder.
    ///   - mode: The access bits.
    ///   - path: The path of the telemetry file, for the error.
    /// - Throws: ``OpenError`` with the `errno` value of `access(2)`.
    private static func requireAccess(_ target: String, _ mode: Int32, for path: String) throws(OpenError) {
        guard access(target, mode) == 0 else {
            throw OpenError(path: path, code: errno)
        }
    }

    /// The folder of `path`.
    ///
    /// - Parameter path: The path of the telemetry file.
    /// - Returns: The folder, or the current folder when the path names none.
    private static func folder(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? currentFolder : folder
    }
}

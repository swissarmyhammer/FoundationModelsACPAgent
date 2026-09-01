import Foundation
import FoundationModelsRouter

/// One line of `sessions.jsonl` (plan.md §4.3): a self-contained summary of
/// one ACP session. The record carries exactly the fields `session/list`
/// reports (§9) — and never a client-supplied `mcpServers` list, because an
/// `http` server's headers carry bearer tokens and this file is committed
/// (§7.3).
public struct SessionIndexRecord: Codable, Equatable, Sendable {
    /// The ACP session id: the ULID of the root Router session, and the
    /// name of the session's directory under the recording root.
    public var sessionId: String

    /// The absolute working directory the session ran in.
    public var cwd: String

    /// The generated title: the first user prompt cut to one line, or the
    /// empty string when a rebuild could not recover it.
    public var title: String

    /// The instant of the session's most recent activity. Serialized as an
    /// RFC 3339 string.
    public var updatedAt: Date

    /// The complete ordered `additionalDirectories` list from the most
    /// recent activation (plan.md §9).
    public var additionalDirectories: [String]

    /// Makes a record from its five fields.
    ///
    /// - Parameters:
    ///   - sessionId: The ACP session id, a ULID string.
    ///   - cwd: The absolute working directory.
    ///   - title: The generated one-line title.
    ///   - updatedAt: The instant of the most recent activity.
    ///   - additionalDirectories: The ordered additional directories.
    public init(
        sessionId: String,
        cwd: String,
        title: String,
        updatedAt: Date,
        additionalDirectories: [String]
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.additionalDirectories = additionalDirectories
    }
}

/// A condition the index read reports and continues past.
public enum SessionIndexWarning: Equatable, Sendable, CustomStringConvertible {
    /// The final line did not decode. `sessions.jsonl` is appended between
    /// fsyncs, so a crash can tear the final line (plan.md §4.1); the read
    /// drops it and keeps every earlier record.
    case tornFinalLine

    /// A human-readable message for the log.
    public var description: String {
        switch self {
        case .tornFinalLine:
            return "\(SessionIndex.indexFileName): dropped a torn final line"
        }
    }
}

/// Why the index refused to read (plan.md §4.1): damage before the final
/// line is not a crash artifact, so the reader does not guess past it.
public enum SessionIndexError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A line before the final one did not decode. `number` is 1-based.
    case corruptLine(number: Int)

    /// A human-readable reason that names the line.
    public var description: String {
        switch self {
        case .corruptLine(let number):
            return "\(SessionIndex.indexFileName): line \(number) is corrupt; "
                + "rebuild the index from the session directories"
        }
    }
}

/// What one read gives: the decoded records and the warnings the read
/// logged on the way.
public struct SessionIndexReadResult: Equatable, Sendable {
    /// The decoded records, in file order.
    public let records: [SessionIndexRecord]

    /// Each warning the read logged, in file order.
    public let warnings: [SessionIndexWarning]
}

/// The append-only `sessions.jsonl` index of one recording root (plan.md
/// §4.3). One self-contained record per line keeps the file mergeable with
/// `merge=union`; the index is a cache, because a scan of the session
/// directories can rebuild it.
public struct SessionIndex: Sendable {
    /// The index file's name inside the recording root.
    public static let indexFileName = "sessions.jsonl"

    /// The `.gitattributes` file the first write materializes.
    public static let gitattributesFileName = ".gitattributes"

    /// The sidecar that marks a directory as a session (plan.md §4.1).
    static let sidecarFileName = "session.json"

    /// The transcript file Router appends inside a session directory; its
    /// modification date is the rebuild's `updatedAt` source.
    static let transcriptFileName = "transcript.jsonl"

    /// The materialized `.gitattributes` content (plan.md §4.3). Git
    /// resolves each pattern relative to the directory that holds the
    /// file — the transcripts root itself — so `**` marks everything under
    /// `transcripts/**` as generated, and `sessions.jsonl` names
    /// `transcripts/sessions.jsonl` for the union merge.
    static let gitattributesContents = """
        ** linguist-generated=true
        sessions.jsonl merge=union
        """

    /// The recording root the index lives in: `<root>/sessions.jsonl`
    /// beside the `<root>/<sessionId>/` session directories.
    public let root: URL

    /// Makes the index of the recording root at `root`.
    ///
    /// - Parameter root: The resolved recording root (plan.md §4.1).
    public init(root: URL) {
        self.root = root
    }

    /// The index file's URL.
    private var indexFile: URL {
        root.appendingPathComponent(Self.indexFileName)
    }

    /// Appends one record as one line. The first write into the root also
    /// creates the directory and materializes `.gitattributes`; an
    /// existing `.gitattributes` is never rewritten.
    ///
    /// - Parameter record: The record to append.
    /// - Throws: A file-system error when the root or the file cannot be
    ///   written.
    public func append(_ record: SessionIndexRecord) throws {
        try materializeRoot()
        try JSONLines.appendLine(JSONLines.encodedLine(of: record), to: indexFile)
    }

    /// Reads every record. A torn final line — the crash artifact §4.1
    /// describes — is dropped with a warning; a corrupt earlier line is
    /// real damage and throws.
    ///
    /// - Returns: The records and the warnings, each in file order. A
    ///   missing file gives an empty result.
    /// - Throws: `SessionIndexError.corruptLine` for a line before the
    ///   final one that does not decode.
    public func read() throws -> SessionIndexReadResult {
        guard FileManager.default.fileExists(atPath: indexFile.path) else {
            return SessionIndexReadResult(records: [], warnings: [])
        }
        let text = try String(contentsOf: indexFile, encoding: .utf8)
        let decoder = JSONLines.makeDecoder()
        let numberedLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { !$0.element.isEmpty }
        var records: [SessionIndexRecord] = []
        var warnings: [SessionIndexWarning] = []
        for (position, numbered) in numberedLines.enumerated() {
            do {
                records.append(
                    try decoder.decode(SessionIndexRecord.self, from: Data(numbered.element.utf8)))
            } catch {
                guard position == numberedLines.count - 1 else {
                    throw SessionIndexError.corruptLine(number: numbered.offset + 1)
                }
                let warning = SessionIndexWarning.tornFinalLine
                transcriptLogger.warning("\(warning.description, privacy: .public)")
                warnings.append(warning)
            }
        }
        return SessionIndexReadResult(records: records, warnings: warnings)
    }

    /// Rebuilds the index from a scan of the session directories and
    /// replaces `sessions.jsonl` with the result. The index is a cache, so
    /// a damaged file is not load-bearing (plan.md §4.3): a directory
    /// counts only when its name parses as a ULID and it holds
    /// `session.json`. The scan cannot recover a generated title or the
    /// additional directories, so each rebuilt record carries an empty
    /// title and an empty list, with `updatedAt` from the newest recorded
    /// file.
    ///
    /// - Parameter cwd: The absolute working directory the rebuilt records
    ///   name; the caller knows the project the root belongs to.
    /// - Returns: The rebuilt records, ordered by session id — time order,
    ///   because ULIDs sort by creation instant.
    /// - Throws: A file-system error when the scan or the rewrite fails.
    public func rebuild(cwd: URL) throws -> [SessionIndexRecord] {
        let records = try scannedRecords(cwd: cwd)
        try materializeRoot()
        var contents = Data()
        for record in records {
            contents.append(try JSONLines.encodedLine(of: record))
        }
        try contents.write(to: indexFile, options: .atomic)
        return records
    }

    /// Creates the root directory when it is absent and materializes
    /// `.gitattributes` on the first write (plan.md §4.3). An existing
    /// `.gitattributes` is the user's file and stays as it is.
    private func materializeRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let attributesFile = root.appendingPathComponent(Self.gitattributesFileName)
        guard !FileManager.default.fileExists(atPath: attributesFile.path) else {
            return
        }
        try Self.gitattributesContents.write(to: attributesFile, atomically: true, encoding: .utf8)
    }

    /// The records a scan of the session directories gives, ordered by
    /// session id.
    private func scannedRecords(cwd: URL) throws -> [SessionIndexRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return entries
            .filter(Self.isSessionDirectory)
            .map { directory in
                SessionIndexRecord(
                    sessionId: directory.lastPathComponent,
                    cwd: cwd.standardizedFileURL.path,
                    title: "",
                    updatedAt: Self.lastActivityDate(inSessionDirectory: directory),
                    additionalDirectories: [])
            }
            .sorted { $0.sessionId < $1.sessionId }
    }

    /// Reports whether `entry` is a session directory (plan.md §4.1): a
    /// directory whose name parses as a ULID and that holds `session.json`.
    private static func isSessionDirectory(_ entry: URL) -> Bool {
        guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return false
        }
        guard ULID(ulidString: entry.lastPathComponent) != nil else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: entry.appendingPathComponent(sidecarFileName).path)
    }

    /// The most recent activity a rebuild can observe: the modification
    /// date of `transcript.jsonl`, or of `session.json` for a session with
    /// no transcript yet, or the current instant when neither date reads.
    /// The date is truncated to a whole second — the precision the RFC 3339
    /// line has — so a rebuilt record equals its own round trip.
    /// `TranscriptStore` shares it for a session the scan finds without an
    /// index line, so the two fallbacks cannot drift.
    static func lastActivityDate(inSessionDirectory directory: URL) -> Date {
        for fileName in [transcriptFileName, sidecarFileName] {
            let file = directory.appendingPathComponent(fileName)
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values?.contentModificationDate {
                return truncatedToWholeSeconds(date)
            }
        }
        return truncatedToWholeSeconds(Date())
    }

    /// `date` with its fractional second dropped, matching the precision of
    /// the serialized RFC 3339 form.
    private static func truncatedToWholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

import Foundation
import FoundationModelsRouter

/// Why the read side refused a request.
public enum TranscriptStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The paged listing received a cursor this store did not mint. Cursor
    /// tokens are opaque; a client must not parse, store or build one.
    case invalidCursor(String)

    /// A human-readable reason that names the refused token.
    public var description: String {
        switch self {
        case .invalidCursor(let token):
            return "invalid session-list cursor: \(token)"
        }
    }
}

/// One page of the paged session listing.
public struct SessionPage: Equatable, Sendable {
    /// The page's records, sorted `updatedAt`-descending with a descending
    /// `sessionId` tiebreak.
    public let records: [SessionRecord]

    /// The opaque token that fetches the next page, or `nil` on the final
    /// page.
    public let nextCursor: String?

    /// Makes a page from its two fields.
    ///
    /// - Parameters:
    ///   - records: The page's records, in listing order.
    ///   - nextCursor: The next page's token, or `nil`.
    public init(records: [SessionRecord], nextCursor: String?) {
        self.records = records
        self.nextCursor = nextCursor
    }
}

/// The read side of the transcripts: the browse records `session/list`
/// serves, the cursor pagination, the cross-project project read, and one
/// session's ordered event stream.
///
/// The listing reads the session folders of a recording root through
/// Router's `RouterSessionDirectory.recordedSessions(in:)`, which decodes
/// the `index.md` of each folder. The store never writes a session record
/// and never reimplements the Router's recording format: one folder per
/// session, so no file is shared by two sessions.
///
/// **The listability predicate**: a session lists when it had a prompt —
/// Router sets `firstActivityAt` at its first submission — and it is a
/// root: no fork parent, and no `agentSpawn`, which Router records for a
/// session that the `agents` tool started.
///
/// **The ownership boundary**: this store never records and never
/// restores. The Router owns event writes, entry reconstruction, and
/// live-session rebuild.
public struct TranscriptStore: Sendable {
    /// The largest page the paged listing serves.
    public static let maximumPageSize = 100

    /// The separator between the cursor's two fields.
    private static let cursorFieldSeparator: Character = ":"

    /// The number of fields a decoded cursor holds: the `updatedAt`
    /// milliseconds and the session id.
    private static let cursorFieldCount = 2

    /// Milliseconds per second — the scale the cursor stores `updatedAt`
    /// at, which keeps the millisecond dates of the records lossless.
    private static let millisecondsPerSecond: Double = 1_000

    /// Where a project's recording root resolves.
    public let location: TranscriptLocation

    /// The validated dotfolder name; the project layer is `.<name>`.
    public let name: DotfolderName

    /// The user layer root, `~/.config/<name>/` in production; tests
    /// inject a value so they never touch the real home directory.
    public let userDirectory: URL

    /// The folder of the project store, one file for each project
    /// (``AgentHome/projectsDirectory``).
    public let projectsDirectory: URL

    /// Makes a store over the location inputs and the projects folder.
    ///
    /// - Parameters:
    ///   - location: Where recording roots resolve.
    ///   - name: The validated dotfolder name.
    ///   - userDirectory: The user layer root.
    ///   - projectsDirectory: The folder of the project store.
    public init(location: TranscriptLocation, name: DotfolderName, userDirectory: URL, projectsDirectory: URL) {
        self.location = location
        self.name = name
        self.userDirectory = userDirectory
        self.projectsDirectory = projectsDirectory
    }

    // MARK: - Sessions

    /// The listable sessions of one project: the record in the `index.md`
    /// of each session folder under the project's recording root.
    ///
    /// - Parameter workingDirectory: The project's absolute working
    ///   directory. An unknown directory gives an empty list, not an error.
    /// - Returns: The records, sorted `updatedAt`-descending with a
    ///   descending `sessionId` tiebreak.
    /// - Throws: Whatever ``listableRecords(in:)`` throws.
    public func sessions(inProject workingDirectory: URL) throws -> [SessionRecord] {
        try Self.listableRecords(in: recordingRoot(inProject: workingDirectory)).sorted(by: Self.sortsBefore)
    }

    /// One page of ``sessions(inProject:)``, for the cursor pagination of
    /// `session/list`.
    ///
    /// The cursor is an opaque token that encodes the sort key — never an
    /// offset — so a session added between two fetches makes no duplicate
    /// and skips no existing entry.
    ///
    /// - Parameters:
    ///   - workingDirectory: The project's absolute working directory.
    ///   - limit: The requested page size, bounded to
    ///     `1...maximumPageSize`.
    ///   - cursor: The previous page's `nextCursor`, or `nil` for the
    ///     first page.
    /// - Returns: The page and, when more sessions remain, the next
    ///   page's token.
    /// - Throws: ``TranscriptStoreError/invalidCursor(_:)`` for a token
    ///   this store did not mint, and whatever ``sessions(inProject:)``
    ///   throws.
    public func sessions(
        inProject workingDirectory: URL, limit: Int, cursor: String?
    ) throws -> SessionPage {
        try Self.page(of: sessions(inProject: workingDirectory), limit: limit, cursor: cursor)
    }

    /// The listable records of one recording root: Router's record of each
    /// session folder, kept when the session had a prompt and is a root.
    /// `session/list` and the snapshot inventory both read a root through
    /// it, so both agree on which sessions are recorded.
    ///
    /// - Parameter root: The recording root.
    /// - Returns: The listable records, in Router's order (newest first).
    ///   A root that does not exist gives none.
    /// - Throws: The error of `RouterSessionDirectory.recordedSessions(in:)`:
    ///   the listing of a root that exists, or the read of an `index.md`
    ///   that does not decode.
    public static func listableRecords(in root: URL) throws -> [SessionRecord] {
        try RouterSessionDirectory.recordedSessions(in: root).filter(isListable)
    }

    /// One page of an already-gathered record list, with the same cursor
    /// tokens, sort order, and page-size bound as
    /// ``sessions(inProject:limit:cursor:)``.
    ///
    /// `session/list` uses this for the unfiltered cross-project
    /// listing: it merges the records of every registered project and
    /// pages the merged list with one cursor implementation, so a token
    /// from the filtered read and a token from the cross-project read
    /// never diverge.
    ///
    /// - Parameters:
    ///   - records: The records to page, in any order; the page sorts
    ///     them into listing order first.
    ///   - limit: The requested page size, bounded to
    ///     `1...maximumPageSize`.
    ///   - cursor: The previous page's `nextCursor`, or `nil` for the
    ///     first page.
    /// - Returns: The page and, when more records remain, the next
    ///   page's token.
    /// - Throws: ``TranscriptStoreError/invalidCursor(_:)`` for a token
    ///   this store did not mint.
    public static func page(
        of records: [SessionRecord], limit: Int, cursor: String?
    ) throws -> SessionPage {
        let key = try cursor.map(decodedCursorKey)
        let sorted = records.sorted(by: sortsBefore)
        let remaining: [SessionRecord]
        if let key {
            remaining = Array(sorted.drop { !sortsAfter($0, key) })
        } else {
            remaining = sorted
        }
        let size = boundedPageSize(limit)
        let page = Array(remaining.prefix(size))
        let nextCursor = remaining.count > size ? page.last.map(encodedCursor) : nil
        return SessionPage(records: page, nextCursor: nextCursor)
    }

    // MARK: - Projects

    /// The live projects of the project store, the earliest `firstSeen`
    /// first. A stale project — one that was moved or deleted — is
    /// skipped, not an error.
    ///
    /// - Returns: The live records.
    /// - Throws: A file-system error when an existing projects folder
    ///   cannot be read.
    public func allProjects() throws -> [ProjectRecord] {
        try ProjectStore(directory: projectsDirectory).projects()
    }

    // MARK: - Transcripts

    /// One session's ordered recorded events. This store never records and
    /// never restores; live restore belongs to the Router. A reimplementation of
    /// restore over `transcript.jsonl` would fork the Router format, and it
    /// would break with no error at the next format change.
    ///
    /// - Parameters:
    ///   - sessionID: The session whose events to return.
    ///   - workingDirectory: The project the session recorded in.
    /// - Returns: The session's events in the merged `(ts, seq)` order, or
    ///   an empty array for an unknown session or project.
    /// - Throws: Whatever the merged event read throws.
    public func transcript(
        for sessionID: ULID, inProject workingDirectory: URL
    ) throws -> [TranscriptEvent] {
        try mergedEvents(inProject: workingDirectory).filter { $0.sessionId == sessionID }
    }

    // MARK: - The listing internals

    /// `limit` bounded to `1...maximumPageSize`.
    static func boundedPageSize(_ limit: Int) -> Int {
        min(max(limit, 1), maximumPageSize)
    }

    /// The project's resolved recording root.
    private func recordingRoot(inProject workingDirectory: URL) -> URL {
        location.recordingRoot(
            workingDirectory: workingDirectory, name: name, userDirectory: userDirectory)
    }

    /// Every recorded event under the project's root, in `(ts, seq)`
    /// order. A missing root gives an empty stream.
    private func mergedEvents(inProject workingDirectory: URL) throws -> [TranscriptEvent] {
        let root = recordingRoot(inProject: workingDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        return try TranscriptEvent.merged(under: root)
    }

    /// Whether a record lists: the session had a prompt, and it is a root —
    /// neither a fork nor a session that the `agents` tool started.
    ///
    /// - Parameter record: The record of one session folder.
    /// - Returns: `true` for a listable record.
    private static func isListable(_ record: SessionRecord) -> Bool {
        record.firstActivityAt != nil && record.forkParentId == nil && record.agentSpawn == nil
    }

    /// The listing order: `updatedAt` descending, then `sessionId`
    /// descending — newest first on both keys, because a ULID sorts by its
    /// creation instant.
    private static func sortsBefore(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        guard lhs.updatedAt == rhs.updatedAt else {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.sessionId.description > rhs.sessionId.description
    }

    // MARK: - The cursor

    /// The decoded sort key a cursor token carries.
    private struct CursorKey {
        /// `updatedAt` in milliseconds since the epoch.
        let updatedAtMilliseconds: Int64

        /// The session id, a ULID string.
        let sessionId: String
    }

    /// `date` at the cursor's millisecond scale.
    private static func milliseconds(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * millisecondsPerSecond).rounded())
    }

    /// Whether `record` sorts strictly after the cursor key in listing
    /// order, so a page never repeats and never skips an entry that was
    /// already listed.
    private static func sortsAfter(_ record: SessionRecord, _ key: CursorKey) -> Bool {
        let recordMilliseconds = milliseconds(of: record.updatedAt)
        guard recordMilliseconds == key.updatedAtMilliseconds else {
            return recordMilliseconds < key.updatedAtMilliseconds
        }
        return record.sessionId.description < key.sessionId
    }

    /// The opaque token that names `record`'s sort key.
    private static func encodedCursor(after record: SessionRecord) -> String {
        let raw = "\(milliseconds(of: record.updatedAt))\(cursorFieldSeparator)\(record.sessionId.description)"
        return Data(raw.utf8).base64EncodedString()
    }

    /// Decodes a token ``encodedCursor(after:)`` minted.
    ///
    /// - Parameter token: The client-supplied cursor.
    /// - Returns: The token's sort key.
    /// - Throws: ``TranscriptStoreError/invalidCursor(_:)`` when the token
    ///   is not base64, does not hold the two fields, or names an id that
    ///   is not a ULID.
    private static func decodedCursorKey(_ token: String) throws -> CursorKey {
        guard
            let data = Data(base64Encoded: token),
            let raw = String(data: data, encoding: .utf8)
        else {
            throw TranscriptStoreError.invalidCursor(token)
        }
        let fields = raw.split(separator: cursorFieldSeparator)
        guard
            fields.count == Self.cursorFieldCount,
            let updatedAtMilliseconds = Int64(fields[0]),
            ULID(ulidString: String(fields[1])) != nil
        else {
            throw TranscriptStoreError.invalidCursor(token)
        }
        return CursorKey(
            updatedAtMilliseconds: updatedAtMilliseconds, sessionId: String(fields[1]))
    }
}

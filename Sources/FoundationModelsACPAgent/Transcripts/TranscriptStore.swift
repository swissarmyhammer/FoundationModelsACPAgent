import Foundation
import FoundationModelsRouter

/// Why the read side refused a request.
public enum TranscriptStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The paged listing received a cursor this store did not mint. Cursor
    /// tokens are opaque (plan.md §9); a client must not build one.
    case invalidCursor(String)

    /// A human-readable reason that names the refused token.
    public var description: String {
        switch self {
        case .invalidCursor(let token):
            return "invalid session-list cursor: \(token)"
        }
    }
}

/// One page of the paged session listing (plan.md §9).
public struct SessionPage: Equatable, Sendable {
    /// The page's records, sorted `updatedAt`-descending with a descending
    /// `sessionId` tiebreak.
    public let records: [SessionIndexRecord]

    /// The opaque token that fetches the next page, or `nil` on the final
    /// page.
    public let nextCursor: String?

    /// Makes a page from its two fields.
    ///
    /// - Parameters:
    ///   - records: The page's records, in listing order.
    ///   - nextCursor: The next page's token, or `nil`.
    public init(records: [SessionIndexRecord], nextCursor: String?) {
        self.records = records
        self.nextCursor = nextCursor
    }
}

/// The read side of the transcripts (plan.md §4.6): the browse summaries
/// `session/list` (§9) serves, the cursor pagination, the cross-project
/// registry read, and one session's ordered event stream.
///
/// The store is built on `TranscriptEvent.merged(under:)` — the one public
/// read the Router gives. The merged events are grouped by `sessionId`, and
/// parentage is rebuilt from `parentId`. The store never reads
/// `session.json` and never reimplements the Router's transcript format.
///
/// **The listability predicate (§9)**: a session lists when it has a
/// persisted transcript — a zero-turn session never wrote one — and it is a
/// root: `parentId == nil` on every event, and no event carries the
/// `agentSpawn` fact the Router stamps on the `session` event of an
/// agent-spawned session. Agent spawns do not occur in this iteration
/// (plan.md §11.3), but the predicate already excludes them, because a
/// later Multitool agents capability will make them.
///
/// **The ownership boundary (§4.6)**: this store never records and never
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
    /// at, which keeps the whole-second RFC 3339 dates lossless.
    private static let millisecondsPerSecond: Double = 1_000

    /// Where a project's recording root resolves (plan.md §4.1).
    public let location: TranscriptLocation

    /// The validated dotfolder name; the project layer is `.<name>`.
    public let name: DotfolderName

    /// The user layer root, `~/.config/<name>/` in production; tests
    /// inject a value so they never touch the real home directory.
    public let userDirectory: URL

    /// Makes a store over the three location inputs.
    ///
    /// - Parameters:
    ///   - location: Where recording roots resolve.
    ///   - name: The validated dotfolder name.
    ///   - userDirectory: The user layer root.
    public init(location: TranscriptLocation, name: DotfolderName, userDirectory: URL) {
        self.location = location
        self.name = name
        self.userDirectory = userDirectory
    }

    // MARK: - Sessions

    /// The listable sessions of one project, joined with the
    /// `sessions.jsonl` records for the title, `updatedAt`, and the
    /// ordered `additionalDirectories`.
    ///
    /// A session the scan finds without an index line still lists, with an
    /// empty title, an empty directory list, and `updatedAt` from the
    /// session directory's newest recorded file. An index record whose
    /// session left no events is excluded. When one session has several
    /// index lines, the last line wins.
    ///
    /// - Parameter workingDirectory: The project's absolute working
    ///   directory. An unknown directory gives an empty list, not an error.
    /// - Returns: The records, sorted `updatedAt`-descending with a
    ///   descending `sessionId` tiebreak.
    /// - Throws: Whatever the merged event read throws, or
    ///   `SessionIndexError.corruptLine` for a damaged index.
    public func sessions(inProject workingDirectory: URL) throws -> [SessionIndexRecord] {
        try sortedListableRecords(inProject: workingDirectory)
    }

    /// One page of ``sessions(inProject:)``, for §9's cursor pagination.
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
        let key = try cursor.map(Self.decodedCursorKey)
        let records = try sortedListableRecords(inProject: workingDirectory)
        let remaining: [SessionIndexRecord]
        if let key {
            remaining = Array(records.drop { !Self.sortsAfter($0, key) })
        } else {
            remaining = records
        }
        let size = Self.boundedPageSize(limit)
        let page = Array(remaining.prefix(size))
        let nextCursor = remaining.count > size ? page.last.map(Self.encodedCursor) : nil
        return SessionPage(records: page, nextCursor: nextCursor)
    }

    // MARK: - Projects

    /// The live cross-project registry entries (plan.md §4.5), in file
    /// order. A stale entry — a project that was moved or deleted — is
    /// skipped, not an error.
    ///
    /// - Returns: The live records.
    /// - Throws: A file-system error when an existing registry file cannot
    ///   be read.
    public func allProjects() throws -> [ProjectRegistryRecord] {
        try ProjectRegistry(directory: userDirectory).projects()
    }

    // MARK: - Transcripts

    /// One session's ordered recorded events. This store never records and
    /// never restores (plan.md §4.6); live restore belongs to the Router.
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

    /// The project's resolved recording root (plan.md §4.1).
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

    /// The listable sessions joined with their index records, in listing
    /// order.
    private func sortedListableRecords(
        inProject workingDirectory: URL
    ) throws -> [SessionIndexRecord] {
        let root = recordingRoot(inProject: workingDirectory)
        let groups = Dictionary(
            grouping: try mergedEvents(inProject: workingDirectory), by: \.sessionId)
        let listableIds = groups.filter { _, events in
            events.allSatisfy { $0.parentId == nil && $0.agentSpawn == nil }
        }.keys
        let storedRecords = try SessionIndex(root: root).read().records
        let recordsBySessionId = Dictionary(
            storedRecords.map { ($0.sessionId, $0) },
            uniquingKeysWith: { _, later in later })
        return
            listableIds
            .map { id in
                recordsBySessionId[id.description]
                    ?? Self.scannedRecord(for: id, under: root, cwd: workingDirectory)
            }
            .sorted(by: Self.sortsBefore)
    }

    /// The record the scan synthesizes for a session with no index line:
    /// an empty title, an empty directory list, and `updatedAt` from the
    /// session directory's newest recorded file — the same source
    /// `SessionIndex.rebuild(cwd:)` uses.
    private static func scannedRecord(
        for id: ULID, under root: URL, cwd: URL
    ) -> SessionIndexRecord {
        SessionIndexRecord(
            sessionId: id.description,
            cwd: cwd.standardizedFileURL.path,
            title: "",
            updatedAt: SessionIndex.lastActivityDate(
                inSessionDirectory: root.appendingPathComponent(id.description, isDirectory: true)),
            additionalDirectories: [])
    }

    /// The listing order (§9): `updatedAt` descending, then `sessionId`
    /// descending — newest first on both keys, because a ULID sorts by its
    /// creation instant.
    private static func sortsBefore(_ lhs: SessionIndexRecord, _ rhs: SessionIndexRecord) -> Bool {
        guard lhs.updatedAt == rhs.updatedAt else {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.sessionId > rhs.sessionId
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
    private static func sortsAfter(_ record: SessionIndexRecord, _ key: CursorKey) -> Bool {
        let recordMilliseconds = milliseconds(of: record.updatedAt)
        guard recordMilliseconds == key.updatedAtMilliseconds else {
            return recordMilliseconds < key.updatedAtMilliseconds
        }
        return record.sessionId < key.sessionId
    }

    /// The opaque token that names `record`'s sort key.
    private static func encodedCursor(after record: SessionIndexRecord) -> String {
        let raw = "\(milliseconds(of: record.updatedAt))\(cursorFieldSeparator)\(record.sessionId)"
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

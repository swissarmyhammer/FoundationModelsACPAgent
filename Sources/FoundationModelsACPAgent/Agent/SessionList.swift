import Foundation
import FoundationModelsACP
import FoundationModelsRouter

extension RoutedACPAgent {
    /// Lists the persisted sessions: the wire surface over
    /// `TranscriptStore`'s listable-record read and its sort-key cursor
    /// pagination.
    ///
    /// A `cwd` filter reads one project; an unknown directory gives an
    /// empty array, not an error. An unfiltered request goes
    /// cross-project through the project store of the home
    /// (``AgentHome/projectsDirectory``). The method is baseline in
    /// ACP v2, so it is never capability-gated — only the order rule
    /// applies.
    ///
    /// - Parameter params: The request: the optional `cwd` filter and
    ///   the optional opaque `cursor` from a previous response.
    /// - Returns: One page of `SessionInfo` records, sorted `updatedAt`
    ///   descending with a descending `sessionId` tiebreak, and the next
    ///   page's cursor when more sessions remain.
    /// - Throws: The order rule's invalid-request error, an
    ///   invalid-params error for a relative `cwd` or for a cursor this
    ///   agent did not mint, or whatever the store read throws.
    public func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        try listSessions(params, from: .direct)
    }

    /// Lists the persisted sessions for one connection: the work of
    /// ``listSessions(_:)``.
    ///
    /// - Parameters:
    ///   - params: The request: the optional `cwd` filter and the optional
    ///     opaque `cursor` from a previous response.
    ///   - caller: The connection of the request.
    /// - Returns: One page of `SessionInfo` records.
    /// - Throws: The errors that ``listSessions(_:)`` names.
    func listSessions(_ params: ListSessionsRequest, from caller: ConnectionId) throws -> ListSessionsResponse {
        try requireInitialized(before: ACPMethod.sessionList, from: caller)
        let records: [SessionRecord]
        if let cwd = params.cwd {
            records = try listableRecords(
                inProject: SessionSetup.validatedWorkingDirectory(
                    path: cwd.rawValue, field: .cwd))
        } else {
            records = try allListableRecords()
        }
        let page: SessionPage
        do {
            page = try TranscriptStore.page(
                of: records,
                limit: TranscriptStore.maximumPageSize,
                cursor: params.cursor?.rawValue)
        } catch TranscriptStoreError.invalidCursor(let token) {
            throw RequestError.invalidSessionListCursor(token)
        }
        return ListSessionsResponse(
            sessions: page.records.compactMap { SessionInfo(record: $0) },
            nextCursor: page.nextCursor.map(SessionListCursor.init(rawValue:)))
    }

    /// The listable records of one project, read through the store the
    /// project's own configuration names: the `transcripts.location` and
    /// the user layer root both come from the project's dotfolder stack,
    /// the same resolution `session/new` records under. A
    /// ``transcriptLocation`` of the host wins over the stack, as it does
    /// for `session/new`.
    ///
    /// - Parameter workingDirectory: The project's absolute working
    ///   directory.
    /// - Returns: The records, in listing order.
    /// - Throws: Whatever the configuration load or the store read
    ///   throws.
    private func listableRecords(inProject workingDirectory: URL) throws -> [SessionRecord] {
        let loader = makeConfigurationLoader(workingDirectory: workingDirectory)
        let store = TranscriptStore(
            location: try loader.load().configuration.transcripts.location,
            name: name,
            userDirectory: SessionSetup.userLayerRoot(of: loader.stack),
            projectsDirectory: home.projectsDirectory)
        return try store.sessions(inProject: workingDirectory)
    }

    /// The merged listable records of every project in the project store
    /// of the home, one record for each session.
    ///
    /// Two projects whose configurations name one shared absolute
    /// recording root each list that root's sessions, so the merge keeps
    /// the first record of each `sessionId` and a page walk sees every
    /// session once.
    ///
    /// - Returns: The merged records; ``listSessions(_:)`` sorts and
    ///   pages them.
    /// - Throws: Whatever the project store read or a project's record read
    ///   throws.
    private func allListableRecords() throws -> [SessionRecord] {
        let merged = try ProjectStore(directory: home.projectsDirectory)
            .projects()
            .flatMap { project in
                try listableRecords(
                    inProject: URL(fileURLWithPath: project.path, isDirectory: true))
            }
        var listedSessionIds: Set<ULID> = []
        return merged.filter { listedSessionIds.insert($0.sessionId).inserted }
    }
}

extension SessionInfo {
    /// The wire projection of one session record: `title`, `updatedAt`
    /// (RFC 3339), and the complete ordered `additionalDirectories` are
    /// always filled.
    ///
    /// The schema requires an absolute `cwd`, and Router records the
    /// absolute working folder of each session; a damaged record whose
    /// `cwd` is not absolute cannot go on the wire, so the projection gives
    /// `nil` and the listing drops that record. A directory entry that is
    /// not absolute is dropped from the list for the same reason. A stored
    /// record is not a request, so there is no client to answer: dropping
    /// is the whole remedy.
    ///
    /// - Parameter record: The record of one session folder.
    init?(record: SessionRecord) {
        guard let cwd = AbsolutePath(absolute: record.workingDirectory.standardizedFileURL.path) else {
            return nil
        }
        self.init(
            cwd: cwd,
            sessionId: SessionId(rawValue: record.sessionId.description),
            additionalDirectories: record.additionalDirectories.compactMap { directory in
                AbsolutePath(absolute: directory.path)
            },
            title: record.facts.title,
            updatedAt: PromptExecution.rfc3339(record.updatedAt))
    }
}

extension RequestError {
    /// The invalid-cursor refusal: JSON-RPC invalid params
    /// with the refused token in `data`, so a client that persisted or
    /// built a token — which the spec forbids — sees which one was
    /// refused.
    ///
    /// - Parameter token: The refused cursor token.
    /// - Returns: The typed invalid-params error.
    static func invalidSessionListCursor(_ token: String) -> RequestError {
        RequestError(
            code: .invalidParams,
            message: RequestError.invalidParams.message,
            data: .object(["cursor": .string(token)]))
    }
}

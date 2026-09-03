import Foundation
import FoundationModelsACP

extension RoutedACPAgent {
    /// The placeholder working directory the registry read resolves its
    /// dotfolder stack against. Only the user layer is read from that
    /// stack, and the user layer does not depend on the working
    /// directory, so any absolute directory gives the same root.
    private static let registryPlaceholderDirectory = URL(fileURLWithPath: "/", isDirectory: true)

    /// Lists the persisted sessions (plan.md §9): the wire surface over
    /// `TranscriptStore`'s listable-record read and its sort-key cursor
    /// pagination.
    ///
    /// A `cwd` filter reads one project; an unknown directory gives an
    /// empty array, not an error. An unfiltered request goes
    /// cross-project through `projects.jsonl`. The method is baseline in
    /// ACP v2, so it is never capability-gated — only the order rule
    /// applies.
    ///
    /// - Parameter params: The request: the optional `cwd` filter and
    ///   the optional opaque `cursor` from a previous response.
    /// - Returns: One page of `SessionInfo` records, sorted `updatedAt`
    ///   descending with a descending `sessionId` tiebreak, and the next
    ///   page's cursor when more sessions remain.
    /// - Throws: The order rule's invalid-request error, an
    ///   invalid-params error for a cursor this agent did not mint, or
    ///   whatever the store read throws.
    public func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        try requireInitialized(before: ACPMethod.sessionList)
        let records: [SessionIndexRecord]
        if let cwd = params.cwd {
            records = try listableRecords(
                inProject: URL(fileURLWithPath: cwd.rawValue, isDirectory: true))
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
    /// the same resolution `session/new` records under (plan.md §4.1).
    ///
    /// - Parameter workingDirectory: The project's absolute working
    ///   directory.
    /// - Returns: The records, in listing order.
    /// - Throws: Whatever the configuration load or the store read
    ///   throws.
    private func listableRecords(inProject workingDirectory: URL) throws -> [SessionIndexRecord] {
        let loader = ConfigurationLoader(
            name: name,
            workingDirectory: workingDirectory,
            userDirectory: userDirectory,
            environment: environment)
        let store = TranscriptStore(
            location: try loader.load().configuration.transcripts.location,
            name: name,
            userDirectory: SessionSetup.userLayerRoot(of: loader.stack))
        return try store.sessions(inProject: workingDirectory)
    }

    /// The merged listable records of every registered project (plan.md
    /// §4.5), one record for each session.
    ///
    /// Two projects whose configurations name one shared absolute
    /// recording root each list that root's sessions, so the merge keeps
    /// the first record of each `sessionId` and a page walk sees every
    /// session once.
    ///
    /// - Returns: The merged records; ``listSessions(_:)`` sorts and
    ///   pages them.
    /// - Throws: Whatever the registry read or a project's record read
    ///   throws.
    private func allListableRecords() throws -> [SessionIndexRecord] {
        let merged = try ProjectRegistry(directory: registryUserLayerRoot())
            .projects()
            .flatMap { project in
                try listableRecords(
                    inProject: URL(fileURLWithPath: project.path, isDirectory: true))
            }
        var listedSessionIds = Set<String>()
        return merged.filter { listedSessionIds.insert($0.sessionId).inserted }
    }

    /// The user layer root the cross-project registry lives in, resolved
    /// with no project: the stack is built over
    /// ``registryPlaceholderDirectory``, because the user layer is the
    /// same for every working directory.
    ///
    /// - Returns: The user layer root.
    private func registryUserLayerRoot() -> URL {
        SessionSetup.userLayerRoot(
            of: ConfigurationLoader(
                name: name,
                workingDirectory: Self.registryPlaceholderDirectory,
                userDirectory: userDirectory,
                environment: environment
            ).stack)
    }
}

extension SessionInfo {
    /// The wire projection of one index record (plan.md §9): `title`,
    /// `updatedAt` (RFC 3339), and the complete ordered
    /// `additionalDirectories` are always filled.
    ///
    /// The schema requires an absolute `cwd`, and every writer of this
    /// package records one; a damaged record whose `cwd` is not absolute
    /// cannot go on the wire, so the projection gives `nil` and the
    /// listing drops that record. A directory entry that is not absolute
    /// is dropped from the list for the same reason.
    ///
    /// - Parameter record: The store's index record.
    init?(record: SessionIndexRecord) {
        guard let cwd = AbsolutePath(rawValue: record.cwd) else {
            return nil
        }
        self.init(
            cwd: cwd,
            sessionId: SessionId(rawValue: record.sessionId),
            additionalDirectories: record.additionalDirectories.compactMap(
                AbsolutePath.init(rawValue:)),
            title: record.title,
            updatedAt: PromptTurn.rfc3339(record.updatedAt))
    }
}

extension RequestError {
    /// The invalid-cursor refusal (plan.md §9): JSON-RPC invalid params
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

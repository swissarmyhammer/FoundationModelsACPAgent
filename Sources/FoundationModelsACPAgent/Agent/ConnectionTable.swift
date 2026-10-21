import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

/// The id of one client connection of the agent (ACPA-5, D120 a).
///
/// ACP v2 names the connection on each call: the HTTP transport gives an
/// `Acp-Connection-Id` at `initialize`. A transport with no connection header
/// (stdio, `InMemoryTransport`) gets an id from the agent at its bind, so each
/// transport takes one path. The id never comes from the client.
public struct ConnectionId: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// The id as text.
    public let rawValue: String

    /// Makes an id from its text.
    ///
    /// - Parameter rawValue: The id as text.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The id as text.
    public var description: String {
        rawValue
    }

    /// The caller of the `Agent` methods of ``RoutedACPAgent`` itself: a test
    /// or an in-process host that calls the agent with no wire, or a wire
    /// whose factory gives the agent and not a ``RoutedACPConnection``. Its
    /// row has no outbound path, so nothing goes out to it.
    public static let direct = ConnectionId(rawValue: "direct")

    /// Mints the id of a new connection: a new ULID, thus unique in the
    /// process.
    ///
    /// - Returns: The new id.
    static func make() -> ConnectionId {
        ConnectionId(rawValue: ULID().ulidString)
    }
}

/// The trust of one connection (D120 b): `userDevice` for the in-process UI
/// and a token of a device of the user, `external` for any other token. The
/// credential of the connection gives it, never the client.
public typealias ConnectionTrust = GraphQLViewer.Trust

/// One row of the ``ConnectionTable``: what the agent knows of one
/// connection.
struct ConnectionRow: Sendable {
    /// The id of the connection.
    let id: ConnectionId

    /// The trust of the connection.
    let trust: ConnectionTrust

    /// The outbound path of the connection: the requests and the
    /// notifications of the agent to the client go through it. `nil` for
    /// ``ConnectionId/direct`` and after the release of the connection.
    ///
    /// The row keeps the connection weakly. The connection keeps the agent
    /// strongly through the ``RoutedACPConnection`` that its factory built,
    /// and a strong reference back would make a cycle that a closed
    /// connection never breaks (task `^173qn8n`). The caller of
    /// `AgentSideConnection.init` keeps the connection for as long as it
    /// serves.
    weak var connection: AgentSideConnection?

    /// The client capabilities that the `initialize` of this connection
    /// read, or `nil` before its first `initialize`.
    var clientCapabilities: NegotiatedClientCapabilities?
}

/// The outbound path of a session: the connection that its requests and
/// notifications go out on, with the client capabilities of that
/// connection.
struct ClientPath: Sendable {
    /// The connection.
    let connection: AgentSideConnection

    /// The client capabilities of the connection. A connection with no
    /// `initialize` reads as "supports nothing".
    let capabilities: NegotiatedClientCapabilities
}

/// The connection table of the agent (ACPA-5, D120): one row for each
/// connection, the owner of each session, and the connection that started
/// each session.
///
/// The agent is one instance for all its connections, as a listener, and it
/// keys its state by these ids. A `Mutex` holds the table outside actor
/// isolation, because the factory closure of `AgentSideConnection` is
/// synchronous and adds the row of its connection during the construction of
/// the connection, and because each outbound path reads the table from a
/// synchronous sink.
///
/// The owner record and the started-by record are in memory only (D120 e):
/// after a restart no session has an owner until a client takes it.
final class ConnectionTable: Sendable {
    /// The rows, the owners and the starters.
    private struct State {
        /// The rows, keyed by the connection id.
        var rows: [ConnectionId: ConnectionRow]

        /// The owner of each session (D11): the connection that its updates
        /// and its requests for the user go out on. `session/new` sets it,
        /// and a `session/resume` that takes the session changes it.
        var owners: [SessionId: ConnectionId] = [:]

        /// The connection that started each session with `session/new`.
        /// The visibility rule of an `external` viewer reads it (ACPA-13).
        /// A take does not change it.
        var starters: [SessionId: ConnectionId] = [:]
    }

    /// The table, under its lock.
    private let state: Mutex<State>

    /// Makes the table with the row of ``ConnectionId/direct`` only. The
    /// direct caller is in process, thus `userDevice`.
    init() {
        let direct = ConnectionRow(id: .direct, trust: .userDevice, connection: nil)
        state = Mutex(State(rows: [.direct: direct]))
    }

    /// Adds the row of a new connection, with a new id.
    ///
    /// - Parameters:
    ///   - connection: The outbound path of the connection.
    ///   - trust: The trust of the connection.
    /// - Returns: The id of the new row.
    func add(_ connection: AgentSideConnection, trust: ConnectionTrust) -> ConnectionId {
        let id = ConnectionId.make()
        let row = ConnectionRow(id: id, trust: trust, connection: connection)
        state.withLock { $0.rows[id] = row }
        return id
    }

    /// Removes the row of a closed connection, and frees each session that
    /// it owns (D120 d): the session then has no owner, and any connection
    /// that can take it may take it. The started-by record stays.
    ///
    /// - Parameter id: The id of the connection.
    func remove(_ id: ConnectionId) {
        state.withLock { state in
            state.rows.removeValue(forKey: id)
            state.owners = state.owners.filter { $0.value != id }
        }
    }

    /// Records the client capabilities of the `initialize` of a connection.
    /// A connection with no row (it closed) records nothing.
    ///
    /// - Parameters:
    ///   - capabilities: The capabilities that `initialize` read.
    ///   - id: The id of the connection.
    func recordClientCapabilities(_ capabilities: NegotiatedClientCapabilities, of id: ConnectionId) {
        state.withLock { $0.rows[id]?.clientCapabilities = capabilities }
    }

    /// The client capabilities of a connection.
    ///
    /// - Parameter id: The id of the connection.
    /// - Returns: The capabilities of its `initialize`, or `nil` before its
    ///   first `initialize` or when the table has no such row.
    func clientCapabilities(of id: ConnectionId) -> NegotiatedClientCapabilities? {
        state.withLock { $0.rows[id]?.clientCapabilities }
    }

    /// The outbound path of a connection.
    ///
    /// - Parameter id: The id of the connection.
    /// - Returns: The connection and its capabilities, or `nil` when the row
    ///   has no outbound path or the table has no such row.
    func path(of id: ConnectionId) -> ClientPath? {
        state.withLock { Self.path(of: id, in: $0) }
    }

    /// Records the start of a session by `session/new`: the connection of
    /// the request owns the session and is its starter.
    ///
    /// - Parameters:
    ///   - sessionId: The new session.
    ///   - id: The id of the connection that started it.
    func recordStart(of sessionId: SessionId, by id: ConnectionId) {
        state.withLock { state in
            state.owners[sessionId] = id
            state.starters[sessionId] = id
        }
    }

    /// Takes a session for a connection (D120 c): the connection becomes
    /// the owner, and the old owner loses the session. A session with no
    /// owner, or one that the connection owns already, can be taken by any
    /// connection. An `external` connection cannot take a session that
    /// another connection owns; a `userDevice` connection can. The check and
    /// the change are one locked step, so two takes cannot both win.
    ///
    /// - Parameters:
    ///   - sessionId: The session to take.
    ///   - id: The id of the connection that takes it.
    /// - Returns: `false` when the rule refuses the take; the owner then does
    ///   not change.
    func take(_ sessionId: SessionId, by id: ConnectionId) -> Bool {
        state.withLock { state in
            let owner = state.owners[sessionId]
            let trust = state.rows[id]?.trust ?? .external
            guard owner == nil || owner == id || trust == .userDevice else {
                return false
            }
            state.owners[sessionId] = id
            return true
        }
    }

    /// The owner of a session.
    ///
    /// - Parameter sessionId: The session.
    /// - Returns: The id of the owner connection, or `nil` when the session
    ///   has no owner.
    func owner(of sessionId: SessionId) -> ConnectionId? {
        state.withLock { $0.owners[sessionId] }
    }

    /// The connection that started a session with `session/new`.
    ///
    /// - Parameter sessionId: The session.
    /// - Returns: The id of the starter, or `nil` when no connection of this
    ///   process started the session.
    func starter(of sessionId: SessionId) -> ConnectionId? {
        state.withLock { $0.starters[sessionId] }
    }

    /// The viewer of one GraphQL call of a connection (ACPA-13, EXTRAS-5):
    /// the id and the trust of the connection, the sessions that it owns,
    /// the sessions that any connection owns, and the sessions that it
    /// started. One locked read gives all of them, so the sets agree.
    ///
    /// A connection with no row (it closed) reads as `external`, as
    /// ``take(_:by:)`` reads it.
    ///
    /// - Parameter id: The id of the connection of the call.
    /// - Returns: The viewer.
    func viewer(of id: ConnectionId) -> GraphQLViewer {
        state.withLock { state in
            GraphQLViewer(
                clientId: id.rawValue,
                trust: state.rows[id]?.trust ?? .external,
                ownedSessions: Self.sessions(in: state.owners, of: id),
                clientOwnedSessions: Set(state.owners.keys.map(\.rawValue)),
                startedSessions: Self.sessions(in: state.starters, of: id))
        }
    }

    /// The ids of the sessions that a record gives to one connection.
    ///
    /// - Parameters:
    ///   - record: The owners or the starters.
    ///   - id: The id of the connection.
    /// - Returns: The ids of the sessions whose entry is `id`.
    private static func sessions(in record: [SessionId: ConnectionId], of id: ConnectionId) -> Set<String> {
        Set(record.filter { $0.value == id }.keys.map(\.rawValue))
    }

    /// The outbound path of a session: the path of its owner.
    ///
    /// - Parameter sessionId: The session.
    /// - Returns: The path, or `nil` when the session has no owner or its
    ///   owner has no outbound path.
    func path(forSession sessionId: SessionId) -> ClientPath? {
        state.withLock { state in
            state.owners[sessionId].flatMap { Self.path(of: $0, in: state) }
        }
    }

    /// The outbound path of a row in `state`.
    ///
    /// - Parameters:
    ///   - id: The id of the connection.
    ///   - state: The table.
    /// - Returns: The path, or `nil` when the row has no outbound path or the
    ///   table has no such row.
    private static func path(of id: ConnectionId, in state: State) -> ClientPath? {
        guard let row = state.rows[id], let connection = row.connection else {
            return nil
        }
        return ClientPath(
            connection: connection,
            capabilities: row.clientCapabilities ?? NegotiatedClientCapabilities(reading: ClientCapabilities()))
    }
}

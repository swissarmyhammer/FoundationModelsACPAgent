import FoundationModelsACP

/// The status report of the MCP servers of one session: one
/// `_mcp_server_status` session update for each server.
///
/// ACP schema-v2.0.0-alpha.7 has no session update for the status of an MCP
/// server. ACP keeps the names that start with `_` free for custom use, so
/// the report is an extension update kind. A client decodes it as
/// `SessionUpdate.unknown("_mcp_server_status", payload)` with no change to
/// FoundationModelsACP. The client task d8d4384 in the
/// FoundationModelsACPClient board reads the same shape: do not change the
/// shape without a change to that task.
///
/// The members of the update:
///
/// - `name`: the server name, the key of the server.
/// - `transport`: `stdio` or `http`. The update has no `transport` member
///   when the agent does not know the transport of the server.
/// - `origin`: `client` or `config`.
/// - `status`: `connected` or `failed`. The shape also has `connecting` and
///   `closed`, which a later live watch of the servers can send.
/// - `reason`: only with `failed`, the fixed agent text of the
///   ``MCPComposition/ServerOutcome/FailureReason``.
///
/// The update is a live status, not a transcript entry. The agent sends it
/// directly, never through the history sink, so the retained history and a
/// replay never hold it. No member holds a URL, a command argument, an `env`
/// value, a `headers` value or the description of an error.
enum MCPServerStatusReport {
    /// The `sessionUpdate` value of the update.
    static let updateKind = "_mcp_server_status"

    /// The names of the members of the update.
    enum MemberName {
        /// The server name.
        static let name = "name"

        /// The transport of the server.
        static let transport = "transport"

        /// The source of the entry of the server.
        static let origin = "origin"

        /// The status of the server.
        static let status = "status"

        /// Why the server is not connected.
        static let reason = "reason"
    }

    /// The status of one server, as the `status` member gives it. The raw
    /// value is the wire text.
    enum Status: String {
        /// The server connected and is ready.
        case connected

        /// The server is not connected. The update gives the reason.
        case failed

        /// The status of the result of a connect.
        ///
        /// - Parameter result: The result of the connect.
        init(_ result: MCPComposition.ServerOutcome.Result) {
            switch result {
            case .connected: self = .connected
            case .failed: self = .failed
            }
        }
    }

    /// The update that reports `outcome`.
    ///
    /// - Parameter outcome: The outcome of one server of the composition.
    /// - Returns: The `_mcp_server_status` update.
    static func update(for outcome: MCPComposition.ServerOutcome) -> SessionUpdate {
        var members: [String: JSONValue] = [
            MemberName.name: .string(outcome.name),
            MemberName.origin: .string(outcome.origin.rawValue),
            MemberName.status: .string(Status(outcome.result).rawValue),
        ]
        members[MemberName.transport] = outcome.transport.map { .string($0.wireName) }
        if case .failed(let reason) = outcome.result {
            members[MemberName.reason] = .string(reason.rawValue)
        }
        return .unknown(updateKind, .object(members))
    }
}

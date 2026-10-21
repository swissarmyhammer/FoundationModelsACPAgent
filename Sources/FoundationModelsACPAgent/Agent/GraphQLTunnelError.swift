import FoundationModelsACP
import FoundationModelsExtras

/// The errors of the GraphQL tunnel itself (ACPA-13): a call that the host
/// cannot route to an endpoint. The tunnel answers each one as a GraphQL
/// result with the error in `errors` and its code in `extensions.code`
/// (EXTRAS-9 rule 8), so the client reads it as each other GraphQL error.
///
/// A session that the call cannot see, or that the agent does not have,
/// gives the toolkit `NOT_FOUND` (``GraphQLToolkitError/notFound(kind:id:)``)
/// and not an error of this type: one answer for both, so the response does
/// not tell that the session exists (EXTRAS-9 rule 4).
enum GraphQLTunnelError: CodedError, Hashable {
    /// `UNKNOWN_ENDPOINT`: the call names an endpoint that the agent does not
    /// have. `known` lists the names of the endpoints that it has.
    case unknownEndpoint(name: String, known: [String])

    /// `SESSION_REQUIRED`: the call names an endpoint with the
    /// session-folder scope and no session. The session selects the folder.
    case sessionRequired(endpoint: String)

    /// The text between two names of a list in a message.
    private static let listSeparator = ", "

    /// The code of the error, for example `UNKNOWN_ENDPOINT`.
    var code: String {
        switch self {
        case .unknownEndpoint: "UNKNOWN_ENDPOINT"
        case .sessionRequired: "SESSION_REQUIRED"
        }
    }

    /// The message of the error: what is wrong, and how to correct the call.
    var message: String {
        switch self {
        case .unknownEndpoint(let name, let known):
            "No endpoint has the name \"\(name)\". The endpoints are: "
                + "\(known.joined(separator: Self.listSeparator)). Send the call with one of these names; "
                + "\(SAH.GraphQL.Method.endpoints) lists them with their schemas."
        case .sessionRequired(let endpoint):
            "The endpoint \"\(endpoint)\" reads the folder of a session, and the call names no session. "
                + "Send the call with the sessionId of the session whose folder to read."
        }
    }

    /// The `NOT_FOUND` of a session that a call names and cannot reach: the
    /// agent does not have it, it is closed, or the viewer cannot see its
    /// folder.
    ///
    /// - Parameter sessionId: The session that the call named.
    /// - Returns: The toolkit error.
    static func sessionNotFound(_ sessionId: SessionId) -> GraphQLToolkitError {
        .notFound(kind: sessionKind, id: sessionId.rawValue)
    }

    /// The kind that a `NOT_FOUND` of a session names.
    private static let sessionKind = "session"
}

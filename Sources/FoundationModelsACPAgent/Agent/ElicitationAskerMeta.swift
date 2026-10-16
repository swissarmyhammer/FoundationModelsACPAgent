import FoundationModelsACP
import FoundationModelsExtras

/// Who asks one question: the `_meta` of `elicitation/create` (task
/// ^6ay176q, elicitation phase 4).
///
/// The ACP request has no field for the asker, so the agent puts two plain
/// keys in its `_meta`, with the names and the JSON shapes of the Extras
/// fields:
///
/// - `agentPath`: the agents that relayed the question, from the agent
///   nearest the user to the agent that asked. The root session has no
///   agent name, so a question of the root session has an empty path, and
///   the key is not present. The client shows its own label for the root.
/// - `source`: the tool that asked. It is the source of the request, which
///   the first relay of a child or an MCP server sets. When the request has
///   none, it is the tool of the run that posted the question, for example
///   `runCode`.
///
/// A key is present only when its value is not empty, and with no key the
/// request has no `_meta`.
enum ElicitationAskerMeta {
    /// The key of the agent path.
    static let agentPathKey = "agentPath"

    /// The key of the source.
    static let sourceKey = "source"

    /// The `_meta` value that names who asks `request`.
    ///
    /// - Parameters:
    ///   - request: The request the tool posted.
    ///   - tool: The tool of the run that posted the question.
    /// - Returns: The `_meta` object, or `nil` when there is no path and no
    ///   source.
    static func meta(for request: ElicitationRequest, tool: String) -> FoundationModelsACP.JSONValue? {
        var members: [String: FoundationModelsACP.JSONValue] = [:]
        if !request.agentPath.isEmpty {
            members[agentPathKey] = .array(request.agentPath.map { .string($0) })
        }
        let source = request.source ?? tool
        if !source.isEmpty {
            members[sourceKey] = .string(source)
        }
        return members.isEmpty ? nil : .object(members)
    }
}

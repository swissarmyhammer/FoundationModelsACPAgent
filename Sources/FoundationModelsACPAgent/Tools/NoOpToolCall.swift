import FoundationModels
import FoundationModelsMultitool
import FoundationModelsRouter

/// The host check that marks a tool call as a no-op (task ^ys32tj4).
///
/// SWE-bench run `no-otel-1011` recorded a model that sent 73 `runCode`
/// calls while one `tools.*` call was pending. Each of these snippets called
/// no `tools.*` verb (`return null`, `return "end 11"`, ...). There are no
/// turns, only async queues: the result of the pending work is injected into
/// the session as a new message, and that message starts the model working
/// again. A call that does nothing while the model waits is thus a no-op.
///
/// Router asks the check before each tool body, only while an operation of
/// the session is pending. The body of a marked call does not run, and the
/// session does not answer it.
///
/// A call is a no-op when its tool is `runCode` and its snippet calls no
/// `tools.*` verb (`MultiTool.callsNoTool(snippet:)`). Each other call is
/// real. `session/new` and `session/resume` both give ``check`` to the
/// session, so the two paths cannot differ.
enum NoOpToolCall {
    /// The name of the code-mode tool of Multitool.
    static let runCodeToolName = "runCode"

    /// The property of a `runCode` call that holds the snippet
    /// (`RunCodeArguments.code`).
    static let snippetProperty = "code"

    /// The check that each session of the agent gets.
    static let check: NoOpToolCallCheck = { toolName, arguments in
        isNoOp(toolName: toolName, arguments: arguments)
    }

    /// Whether a tool call is a no-op.
    ///
    /// - Parameters:
    ///   - toolName: The name of the called tool.
    ///   - arguments: The arguments of the call.
    /// - Returns: `true` for a `runCode` call whose snippet calls no
    ///   `tools.*` verb. `false` for a call of each other tool, and for a
    ///   `runCode` call with no snippet.
    static func isNoOp(toolName: String, arguments: GeneratedContent) -> Bool {
        guard toolName == runCodeToolName,
            let snippet = try? arguments.value(String.self, forProperty: snippetProperty)
        else {
            return false
        }
        return MultiTool.callsNoTool(snippet: snippet)
    }
}

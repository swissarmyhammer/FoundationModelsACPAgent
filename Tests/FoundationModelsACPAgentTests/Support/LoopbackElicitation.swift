import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import MCPTestServer

/// The loopback eliciting wiring that the elicitation suites share: one
/// session that mounts the `mcp-test-server` executable in loopback mode,
/// whose scripted model runs one code-mode snippet against it.
extension ScriptedPromptFixture {
    /// The name the eliciting MCP test server mounts under.
    static let loopbackServerName = "elicitor"

    /// The snippet that runs the form-mode eliciting loopback tool.
    static let loopbackFormSnippet =
        "return await tools.\(loopbackServerName).\(ScriptedServer.elicitEchoToolName)({});"

    /// Wires a fixture whose session mounts the loopback `mcp-test-server`
    /// and whose scripted model runs `code` in one tool pass, on each prompt
    /// that contains `marker` only.
    ///
    /// - Parameters:
    ///   - code: The snippet the pass runs.
    ///   - capabilities: The client capabilities `initialize` announces.
    ///   - label: The directory label of the calling test.
    ///   - marker: A text that only the prompts that run `code` contain.
    /// - Returns: The fixture.
    /// - Throws: Whatever the wiring throws.
    static func makeLoopback(
        code: String,
        capabilities: ClientCapabilities = ACPClient.advertisedCapabilities,
        label: String,
        onPromptContaining marker: String
    ) async throws -> ScriptedPromptFixture {
        try await make(
            script: makeToolPromptScript(code: code, onPromptContaining: marker),
            label: label,
            capabilities: capabilities,
            mcpServers: [makeLoopbackServer()])
    }

    /// The client MCP server entry of the loopback `mcp-test-server`. A
    /// `session/resume` of a loopback session passes it again, because the
    /// client's `mcpServers` are authoritative on each reconnect.
    ///
    /// - Returns: The server entry.
    /// - Throws: The error of the lookup of the built test server.
    static func makeLoopbackServer() throws -> FoundationModelsACP.MCPServer {
        .stdio(
            MCPServerStdio(
                command: AbsolutePath(rawValue: try BuiltProductLocator.mcpTestServerURL().path),
                name: loopbackServerName,
                args: [ServerMode.flagName, ServerMode.loopback.rawValue]))
    }
}

import Foundation
import FoundationModels
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The shared helpers that invoke the mounted `tools.shell.execute` verb
/// in a built registry. `SandboxCompositionTests` and
/// `TerminalStreamTests` run real commands through the same door, so the
/// helpers live here once.
enum ShellVerbSupport {
    /// The surface path of the shell execute verb.
    static let executeVerbPath = "shell.execute"

    /// Invokes `tools.shell.execute` and returns the rendered report.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose execute verb to invoke.
    ///   - command: The shell command to run.
    ///   - workingDirectory: The directory the command runs in.
    /// - Returns: The verb's rendered answer.
    /// - Throws: Whatever the invocation throws.
    static func invokeExecute(
        in registry: MultiTool.Registry, command: String, workingDirectory: URL
    ) async throws -> String {
        let tool = try #require(registry.tools[executeVerbPath])
        let argumentsJSON = try executeArgumentsJSON(
            command: command, workingDirectory: workingDirectory)
        let output = try await ToolInvoker.invoke(
            tool, content: try GeneratedContent(json: argumentsJSON))
        return try #require(output as? String)
    }

    /// The wire JSON of one execute call.
    ///
    /// - Parameters:
    ///   - command: The shell command to run.
    ///   - workingDirectory: The directory the command runs in.
    /// - Returns: The arguments as JSON text.
    /// - Throws: Whatever the encode throws.
    static func executeArgumentsJSON(
        command: String, workingDirectory: URL
    ) throws -> String {
        let arguments = ["command": command, "workingDirectory": workingDirectory.path]
        return String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
    }
}

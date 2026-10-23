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

    /// The surface path of the shell verb that reads the lines of one command.
    static let getLinesVerbPath = "shell.getLines"

    /// The surface path of the shell verb that searches the stored lines.
    static let grepHistoryVerbPath = "shell.grepHistory"

    /// Invokes `tools.shell.execute` and decodes its rendered report: the
    /// JSON object with `commandID`, `sessionID` and the rest.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose execute verb to invoke.
    ///   - command: The shell command to run.
    ///   - workingDirectory: The directory the command runs in.
    /// - Returns: The fields of the report.
    /// - Throws: Whatever the invocation or the decode throws.
    static func executeReport(
        in registry: MultiTool.Registry, command: String, workingDirectory: URL
    ) async throws -> [String: Any] {
        let answer = try await invokeExecute(in: registry, command: command, workingDirectory: workingDirectory)
        return try decodedObject(answer)
    }

    /// Invokes `tools.shell.getLines` for every line of one command.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose verb to invoke.
    ///   - commandID: The command whose lines to read.
    /// - Returns: The fields of the result: `lines`, `sessionID` and the rest.
    /// - Throws: Whatever the invocation or the decode throws.
    static func getLines(in registry: MultiTool.Registry, commandID: String) async throws -> [String: Any] {
        try await invokeStructured(getLinesVerbPath, in: registry, arguments: ["commandID": commandID])
    }

    /// Invokes `tools.shell.grepHistory` over every stored command.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose verb to invoke.
    ///   - pattern: The text to search for, matched as a literal.
    /// - Returns: The fields of the result: `matches` and the rest.
    /// - Throws: Whatever the invocation or the decode throws.
    static func grepHistory(in registry: MultiTool.Registry, pattern: String) async throws -> [String: Any] {
        let arguments: [String: any Sendable] = ["pattern": pattern, "literal": true]
        return try await invokeStructured(grepHistoryVerbPath, in: registry, arguments: arguments)
    }

    /// Invokes the verb at `path` whose output is a generable value, and
    /// decodes that value as a JSON object.
    ///
    /// - Parameters:
    ///   - path: The surface path of the verb.
    ///   - registry: The built registry that holds the verb.
    ///   - arguments: The arguments of the call.
    /// - Returns: The fields of the output.
    /// - Throws: Whatever the invocation or the decode throws.
    private static func invokeStructured(
        _ path: String, in registry: MultiTool.Registry, arguments: [String: any Sendable]
    ) async throws -> [String: Any] {
        let tool = try #require(registry.tools[path])
        let argumentsData = try JSONSerialization.data(withJSONObject: arguments)
        let output = try await ToolInvoker.invoke(
            tool, content: try GeneratedContent(json: String(decoding: argumentsData, as: UTF8.self)))
        let content = try #require(output as? any ConvertibleToGeneratedContent)
        return try decodedObject(content.generatedContent.jsonString)
    }

    /// Decodes `text` as one JSON object.
    ///
    /// - Parameter text: The JSON text.
    /// - Returns: The fields of the object.
    /// - Throws: When the text is not a JSON object.
    static func decodedObject(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
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

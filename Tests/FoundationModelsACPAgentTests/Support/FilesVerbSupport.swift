import Foundation
import FoundationModels
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The shared helpers that invoke the mounted `tools.files` verbs.
/// `ToolCatalogTests` and `SessionResumeTests` read files through the same
/// door, so the helpers live here once, in the pattern of
/// ``ShellVerbSupport``.
enum FilesVerbSupport {
    /// The surface path of the files read verb.
    static let readVerbPath = "files.read"

    /// The surface path of the files grep verb.
    static let grepVerbPath = "files.grep"

    /// The surface path of the files glob verb.
    static let globVerbPath = "files.glob"

    /// The grep output mode that carries only the paths of the matching
    /// files.
    static let filesWithMatchesMode = "filesWithMatches"

    /// The slice of the grep and glob wire results these tests assert on:
    /// the relative path of each file the search gave.
    ///
    /// The verbs' own output structs are internal upstream; the wire JSON
    /// is the public shape. Grep carries `files` only in the
    /// `filesWithMatches` mode.
    struct SearchVerbResult: Decodable {
        /// The relative path of each file the search gave, or `nil` when
        /// the result holds no file list.
        let files: [String]?

        /// Why the search answered no result, or `nil` when the result
        /// stands.
        let correction: String?
    }

    /// The slice of the read verb's wire result these tests assert on.
    ///
    /// The verb's own output struct is internal upstream; the wire JSON is
    /// the public shape, and a refused read answers in band through
    /// `correction` rather than a thrown error.
    struct ReadVerbResult: Decodable {
        /// Why the read answered no content, or `nil` when the content
        /// stands.
        let correction: String?

        /// The selected window of lines.
        let lines: [String]
    }

    /// Invokes a mounted `tools.files.read` verb on `path` and decodes
    /// the wire result.
    ///
    /// - Parameters:
    ///   - tool: The mounted read verb to invoke.
    ///   - path: The path argument to read.
    /// - Returns: The decoded wire result.
    /// - Throws: Whatever the invocation or the decode throws.
    static func invokeRead(
        _ tool: any FoundationModels.Tool, path: String
    ) async throws -> ReadVerbResult {
        try await invoke(tool, arguments: ["path": path])
    }

    /// Invokes the mounted `tools.files.grep` verb of `registry` over the
    /// session root, in the `filesWithMatches` mode, and decodes the wire
    /// result.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose grep verb to invoke.
    ///   - pattern: The regular expression to match.
    /// - Returns: The decoded wire result.
    /// - Throws: Whatever the invocation or the decode throws.
    static func invokeGrep(
        in registry: MultiTool.Registry, pattern: String
    ) async throws -> SearchVerbResult {
        try await invoke(
            try #require(registry.tools[grepVerbPath]),
            arguments: ["pattern": pattern, "outputMode": filesWithMatchesMode])
    }

    /// Invokes the mounted `tools.files.glob` verb of `registry` over the
    /// session root, and decodes the wire result.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose glob verb to invoke.
    ///   - pattern: The glob pattern to match.
    /// - Returns: The decoded wire result.
    /// - Throws: Whatever the invocation or the decode throws.
    static func invokeGlob(
        in registry: MultiTool.Registry, pattern: String
    ) async throws -> SearchVerbResult {
        try await invoke(try #require(registry.tools[globVerbPath]), arguments: ["pattern": pattern])
    }

    /// Invokes a mounted verb with string arguments and decodes its wire
    /// result. ``GitVerbSupport`` invokes the git verbs through this same
    /// door.
    ///
    /// - Parameters:
    ///   - tool: The mounted verb to invoke.
    ///   - arguments: The string arguments, by name.
    /// - Returns: The decoded wire result.
    /// - Throws: Whatever the invocation or the decode throws.
    static func invoke<Result: Decodable>(
        _ tool: any FoundationModels.Tool, arguments: [String: String]
    ) async throws -> Result {
        let argumentsJSON = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
        let output = try await ToolInvoker.invoke(
            tool, content: try GeneratedContent(json: argumentsJSON))
        let convertible = try #require(output as? any ConvertibleToGeneratedContent)
        return try JSONDecoder().decode(
            Result.self, from: Data(convertible.generatedContent.jsonString.utf8))
    }
}

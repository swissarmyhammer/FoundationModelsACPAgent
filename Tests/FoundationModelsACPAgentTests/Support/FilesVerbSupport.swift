import Foundation
import FoundationModels
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The shared helpers that invoke the mounted `tools.files.read` verb.
/// `ToolCatalogTests` and `SessionResumeTests` read files through the same
/// door, so the helpers live here once, in the pattern of
/// ``ShellVerbSupport``.
enum FilesVerbSupport {
    /// The surface path of the files read verb.
    static let readVerbPath = "files.read"

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
        let argumentsJSON = String(
            decoding: try JSONEncoder().encode(["path": path]), as: UTF8.self)
        let output = try await ToolInvoker.invoke(
            tool, content: try GeneratedContent(json: argumentsJSON))
        let convertible = try #require(output as? any ConvertibleToGeneratedContent)
        return try JSONDecoder().decode(
            ReadVerbResult.self, from: Data(convertible.generatedContent.jsonString.utf8))
    }
}

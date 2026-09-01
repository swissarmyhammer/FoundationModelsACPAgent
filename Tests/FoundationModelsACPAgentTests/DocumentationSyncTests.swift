import Foundation
import FoundationModelsACPAgent
import Testing

/// The discoverability obligation of the compiled-in floor (plan.md §3.1):
/// the README shows the builtin instructions text verbatim, so the text on
/// the page cannot drift from the text in the binary.
@Suite struct DocumentationSyncTests {
    /// The repository's `README.md`, found relative to this source file.
    static var readmeURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FoundationModelsACPAgentTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // the repository root
            .appendingPathComponent("README.md")
    }

    @Test func readmeShowsTheBuiltinInstructionsVerbatim() throws {
        let readme = try String(contentsOf: Self.readmeURL, encoding: .utf8)

        #expect(readme.contains(BuiltinInstructions.text))
    }
}

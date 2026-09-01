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

    /// The heading of the README's tool roster section (plan.md §11.1,
    /// catalog contract step 3).
    static let toolsHeading = "## Tools"

    @Test func readmeShowsTheBuiltinInstructionsVerbatim() throws {
        let readme = try String(contentsOf: Self.readmeURL, encoding: .utf8)

        #expect(readme.contains(BuiltinInstructions.text))
    }

    /// Catalog contract step 3 (plan.md §11.1): the README's `## Tools`
    /// table names every capability of the roster. The roster is
    /// `ToolsConfiguration.CodingKeys`, the same list the config codec
    /// decodes, so a new roster entry fails this test until the table
    /// gains its row.
    @Test func readmeToolsTableNamesEveryCapability() throws {
        let readme = try String(contentsOf: Self.readmeURL, encoding: .utf8)

        #expect(readme.contains(Self.toolsHeading))
        for capability in ToolsConfiguration.CodingKeys.allCases {
            #expect(
                readme.contains("| `\(capability.stringValue)` |"),
                "README § Tools has no row for \(capability.stringValue)")
        }
    }
}

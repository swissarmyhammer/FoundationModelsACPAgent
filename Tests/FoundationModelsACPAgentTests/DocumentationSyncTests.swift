import Foundation
import FoundationModelsACPAgent
import Testing

/// The discoverability obligation of the compiled-in floor (plan.md §3.1):
/// the README points a reader at the one copy of the builtin instructions
/// text. The README does not repeat the text — a second copy is a copy that
/// goes stale — so what this suite protects is the link, not the prose.
@Suite struct DocumentationSyncTests {
    /// The repository root, found relative to this source file.
    static var repositoryRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FoundationModelsACPAgentTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // the repository root
    }

    /// The repository's `README.md`.
    static var readmeURL: URL {
        repositoryRootURL.appendingPathComponent("README.md")
    }

    /// The repository-relative path of the one copy of the builtin
    /// instructions text — the link target the README must carry.
    static let builtinInstructionsPath =
        "Sources/FoundationModelsACPAgent/Instructions/BuiltinInstructions.swift"

    /// The heading of the README's tool roster section (plan.md §11.1,
    /// catalog contract step 3).
    static let toolsHeading = "## Tools"

    /// The README links to the builtin instructions source, and that path
    /// resolves. A moved or renamed file fails here, at the link, instead
    /// of silently leaving the README pointing at nothing.
    @Test func readmeLinksToTheBuiltinInstructionsSource() throws {
        let readme = try String(contentsOf: Self.readmeURL, encoding: .utf8)

        #expect(readme.contains(Self.builtinInstructionsPath))
        #expect(
            FileManager.default.fileExists(
                atPath: Self.repositoryRootURL
                    .appendingPathComponent(Self.builtinInstructionsPath).path))
    }

    /// The README does not repeat the builtin instructions text. One copy
    /// only: the source file the link names.
    @Test func readmeDoesNotRepeatTheBuiltinInstructionsText() throws {
        let readme = try String(contentsOf: Self.readmeURL, encoding: .utf8)

        #expect(!readme.contains(BuiltinInstructions.text))
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

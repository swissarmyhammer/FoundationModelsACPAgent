import FoundationModelsACPAgent
import Testing

/// The validation matrix of `DotfolderName` (plan.md §2.1). A name becomes a
/// path component, so each bad shape is a hard error at construction.
@Suite struct DotfolderNameTests {
    /// Each invalid name and the error it must throw.
    static let invalidNames: [(name: String, error: DotfolderNameError)] = [
        ("", .empty),
        ("a/b", .containsPathSeparator(name: "a/b")),
        ("a\\b", .containsPathSeparator(name: "a\\b")),
        (".", .directoryReference(name: ".")),
        ("..", .directoryReference(name: "..")),
        (".x", .leadingDot(name: ".x")),
    ]

    /// Each invalid name throws its own error at construction.
    @Test(arguments: invalidNames)
    func invalidNameThrowsAtConstruction(name: String, error: DotfolderNameError) {
        #expect(throws: error) {
            try DotfolderName(name)
        }
    }

    /// A bare word is accepted and kept as given.
    @Test(arguments: ["coding", "acme", "my-agent", "agent_2"])
    func bareWordIsAccepted(name: String) throws {
        let dotfolderName = try DotfolderName(name)
        #expect(dotfolderName.rawValue == name)
        #expect(dotfolderName.description == name)
    }

    /// Each error names the rule it enforces, so a caller can show it.
    @Test func errorDescriptionsNameTheRule() {
        #expect(DotfolderNameError.empty.description.contains("empty"))
        #expect(
            DotfolderNameError.containsPathSeparator(name: "a/b").description.contains("a/b"))
        #expect(DotfolderNameError.directoryReference(name: "..").description.contains(".."))
        #expect(DotfolderNameError.leadingDot(name: ".x").description.contains(".x"))
    }
}

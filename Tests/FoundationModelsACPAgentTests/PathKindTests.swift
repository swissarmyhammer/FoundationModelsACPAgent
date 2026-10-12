import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The one file-system probe that tells a missing path, a directory, and
/// something that is not a directory apart. `session/new`, `session/resume`
/// and the `doctor` checks all read it.
@Suite struct PathKindTests {
    /// The name of the plain file a test writes in place of a directory.
    private static let plainFileName = "plain.txt"

    /// The name of the path a test never creates.
    private static let missingName = "missing"

    /// The name of the symbolic link a test makes to a directory.
    private static let linkName = "link"

    /// A path that holds nothing is missing.
    @Test func aMissingPathIsMissing() {
        let missing = makeResolvedDirectory(label: "PathKindTests-missing")
            .appendingPathComponent(Self.missingName, isDirectory: true)

        #expect(PathKind.of(missing) == .missing)
    }

    /// A path that holds a directory is a directory.
    @Test func anExistingDirectoryIsADirectory() {
        let directory = makeResolvedDirectory(label: "PathKindTests-directory")

        #expect(PathKind.of(directory) == .directory)
    }

    /// A path that holds a plain file is not a directory.
    @Test func aPlainFileIsNotADirectory() throws {
        let file = makeResolvedDirectory(label: "PathKindTests-file")
            .appendingPathComponent(Self.plainFileName)
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)

        #expect(PathKind.of(file) == .notADirectory)
    }

    /// A symbolic link to a directory is a directory: the probe follows
    /// the link.
    @Test func aSymbolicLinkToADirectoryIsADirectory() throws {
        let target = makeResolvedDirectory(label: "PathKindTests-link-target")
        let link = makeResolvedDirectory(label: "PathKindTests-link")
            .appendingPathComponent(Self.linkName, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(PathKind.of(link) == .directory)
    }
}

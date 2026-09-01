import Foundation
import FoundationModelsACPAgent
import Testing

/// Recording-root resolution for `transcripts.location` (plan.md §4.1):
/// `project` gives `<cwd>/.<name>/transcripts/`, `home` gives a shared root
/// with one `-Users-…` slug per project, and an absolute path is used as
/// given.
@Suite struct TranscriptLocationTests {
    /// The dotfolder name each resolution in this suite is for.
    static let agentName = "testagent"

    /// A working directory that never exists; resolution is pure path math.
    static let workingDirectory = URL(fileURLWithPath: "/Users/dev/example", isDirectory: true)

    /// An injected user layer root, in place of `~/.config/<name>/`.
    static let userDirectory = URL(
        fileURLWithPath: "/Users/dev/.config/testagent", isDirectory: true)

    /// Resolves `location` against the suite's fixed directories.
    private func resolve(_ location: TranscriptLocation) throws -> URL {
        try location.recordingRoot(
            workingDirectory: Self.workingDirectory,
            name: DotfolderName(Self.agentName),
            userDirectory: Self.userDirectory)
    }

    /// The default configuration resolves the recording root to
    /// `<cwd>/.<name>/transcripts/`.
    @Test func defaultConfigurationResolvesTheProjectRoot() throws {
        let location = AgentConfiguration().transcripts.location

        let root = try resolve(location)

        #expect(root.path == "/Users/dev/example/.testagent/transcripts")
    }

    /// The `home` location resolves to the shared root under the user layer,
    /// with the working directory as a `-Users-…` slug.
    @Test func homeLocationResolvesTheSharedRootWithASlug() throws {
        let root = try resolve(.home)

        #expect(root.path == "/Users/dev/.config/testagent/transcripts/-Users-dev-example")
    }

    /// An absolute location is used as given, with no added components.
    @Test func absoluteLocationIsUsedAsGiven() throws {
        let absolute = URL(fileURLWithPath: "/var/data/transcripts", isDirectory: true)

        let root = try resolve(.path(absolute))

        #expect(root.path == "/var/data/transcripts")
    }

    /// The slug replaces every character that is not a letter or a digit, so
    /// the whole path becomes one safe directory name.
    @Test func projectSlugReplacesEveryUnsafeCharacter() {
        let workingDirectory = URL(
            fileURLWithPath: "/Users/dev/my.repo_x", isDirectory: true)

        let slug = TranscriptLocation.projectSlug(forWorkingDirectory: workingDirectory)

        #expect(slug == "-Users-dev-my-repo-x")
    }

    /// Two different working directories give two different slugs, so two
    /// projects never share a session directory under the shared root.
    @Test func differentWorkingDirectoriesGiveDifferentSlugs() {
        let first = TranscriptLocation.projectSlug(
            forWorkingDirectory: URL(fileURLWithPath: "/Users/dev/one", isDirectory: true))
        let second = TranscriptLocation.projectSlug(
            forWorkingDirectory: URL(fileURLWithPath: "/Users/dev/two", isDirectory: true))

        #expect(first != second)
    }
}

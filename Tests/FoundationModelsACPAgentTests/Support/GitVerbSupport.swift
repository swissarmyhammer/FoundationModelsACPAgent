import Foundation
import FoundationModelsMultitool
import Testing

/// The shared helpers of the tests of the mounted `tools.git` verbs: the
/// surface path of each verb, a temporary git repository with one commit,
/// and the invoke of `tools.git.status`, in the pattern of
/// ``FilesVerbSupport``.
enum GitVerbSupport {
    /// The noun the git capability owns on the surface.
    static let gitNoun = "git"

    /// The surface path of the git status verb.
    static let statusVerbPath = "git.status"

    /// The surface path of each read-only verb that the git capability
    /// mounts.
    static let verbPaths = [
        "git.blame", "git.show", "git.log", "git.commit", statusVerbPath, "git.branches",
        "git.changes", "git.diff",
    ]

    /// The git executable that makes the temporary repository.
    private static let gitExecutablePath = "/usr/bin/git"

    /// The name of the one file that the first commit adds.
    private static let trackedFileName = "tracked.txt"

    /// The configuration of each git command: an author, and no signature,
    /// so the commit does not read the configuration of the machine.
    private static let commitConfiguration = [
        "-c", "user.name=GitVerbSupport", "-c", "user.email=git-verb-support@example.invalid",
        "-c", "commit.gpgsign=false",
    ]

    /// The environment additions that keep the global and the system git
    /// configuration of the machine out of each git command.
    private static let isolatedConfiguration = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    ]

    /// The slice of the status verb's wire result these tests assert on.
    ///
    /// The verb's own output struct is internal upstream; the wire JSON is
    /// the public shape.
    struct StatusVerbResult: Decodable {
        /// The branch that HEAD names, or `nil` for a detached HEAD.
        let branch: String?

        /// Why the status answered no list, or `nil` when the lists stand.
        let correction: String?
    }

    /// Makes a git repository in `directory` with one commit on `branch`.
    ///
    /// - Parameters:
    ///   - directory: The directory that becomes the work tree. It must
    ///     exist.
    ///   - branch: The name of the branch of the first commit.
    /// - Throws: Whatever the file write or a git command throws, and an
    ///   expectation failure when a git command exits with an error.
    static func makeRepository(in directory: URL, branch: String) throws {
        try runGit(["init", "--quiet", "--initial-branch=\(branch)"], in: directory)
        try "tracked\n".write(
            to: directory.appendingPathComponent(trackedFileName), atomically: true, encoding: .utf8)
        try runGit(["add", trackedFileName], in: directory)
        try runGit(
            commitConfiguration + ["commit", "--quiet", "--no-verify", "-m", "the first commit"],
            in: directory)
    }

    /// Invokes the mounted `tools.git.status` verb of `registry` and decodes
    /// the wire result.
    ///
    /// - Parameter registry: The built registry whose status verb to invoke.
    /// - Returns: The decoded wire result.
    /// - Throws: Whatever the invocation or the decode throws.
    static func invokeStatus(in registry: MultiTool.Registry) async throws -> StatusVerbResult {
        try await FilesVerbSupport.invoke(try #require(registry.tools[statusVerbPath]), arguments: [:])
    }

    /// Runs one git command in `directory`, and waits for it to end.
    ///
    /// - Parameters:
    ///   - arguments: The arguments of the command.
    ///   - directory: The working directory of the command.
    /// - Throws: Whatever the process start throws, and an expectation
    ///   failure when the command exits with an error.
    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutablePath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(isolatedConfiguration) {
            _, isolated in isolated
        }
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments) exited with an error")
    }
}

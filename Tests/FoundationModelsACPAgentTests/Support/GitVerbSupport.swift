import Foundation
import FoundationModelsMultitool
import Testing

/// The shared helpers of the tests of the mounted `tools.git` verbs: the
/// surface path of each verb, a temporary git repository with one commit or
/// with a detached HEAD, and the invoke of `tools.git.status`,
/// `tools.git.changes`, and `tools.git.diff`, in the pattern of
/// ``FilesVerbSupport``.
enum GitVerbSupport {
    /// The noun the git capability owns on the surface.
    static let gitNoun = "git"

    /// The surface path of the git status verb.
    static let statusVerbPath = "git.status"

    /// The surface path of the git changes verb.
    static let changesVerbPath = "git.changes"

    /// The surface path of the git diff verb.
    static let diffVerbPath = "git.diff"

    /// The surface path of each read-only verb that the git capability
    /// mounts.
    static let verbPaths = [
        "git.blame", "git.show", "git.log", "git.commit", statusVerbPath, "git.branches",
        changesVerbPath, diffVerbPath,
    ]

    /// The name of the Swift source file that the second commit of a
    /// detached-HEAD repository adds.
    static let sourceFileName = "Greeting.swift"

    /// The git executable that makes the temporary repository.
    private static let gitExecutablePath = "/usr/bin/git"

    /// The name of the one file that the first commit adds.
    private static let trackedFileName = "tracked.txt"

    /// The text of the file that the first commit adds.
    private static let trackedFileText = "tracked\n"

    /// The text of the Swift source file that the second commit of a
    /// detached-HEAD repository adds: one function.
    private static let sourceFileText = """
        func greeting() -> String {
            "hello"
        }

        """

    /// The comment line that ``appendCommentLine(in:)`` adds at the end of
    /// the Swift source file.
    private static let appendedCommentLine = "// The comment line that the test adds at the end of the file.\n"

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

    /// The slice of the changes verb's wire result these tests assert on.
    ///
    /// The verb's own output struct is internal upstream; the wire JSON is
    /// the public shape.
    struct ChangesVerbResult: Decodable {
        /// The branch the verb read: a branch name, or `HEAD` for a detached
        /// HEAD.
        let branch: String

        /// The paths of the files that changed, relative to the root.
        let files: [String]

        /// Why the verb answered no list, or `nil` when the files stand.
        let correction: String?
    }

    /// The slice of the diff verb's wire result these tests assert on.
    ///
    /// The verb's own output struct is internal upstream; the wire JSON is
    /// the public shape.
    struct DiffVerbResult: Decodable {
        /// One change to one entity of the diff.
        struct Change: Decodable {
            /// The kind of the entity, or `lines` for changed lines that no
            /// entity holds.
            let entityType: String

            /// The path of the file that holds the entity, relative to the
            /// root.
            let filePath: String
        }

        /// The changes, file by file.
        let changes: [Change]

        /// Why the diff answered no change, or `nil` when the changes stand.
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
        try commitFile(
            named: trackedFileName, text: trackedFileText, message: "the first commit", in: directory)
    }

    /// Makes a git repository in `directory` with two commits on `branch`,
    /// and then detaches HEAD at the second commit. The second commit adds
    /// the Swift source file ``sourceFileName``.
    ///
    /// - Parameters:
    ///   - directory: The directory that becomes the work tree. It must
    ///     exist.
    ///   - branch: The name of the branch of the two commits.
    /// - Throws: Whatever the file write or a git command throws, and an
    ///   expectation failure when a git command exits with an error.
    static func makeDetachedRepository(in directory: URL, branch: String) throws {
        try makeRepository(in: directory, branch: branch)
        try commitFile(
            named: sourceFileName, text: sourceFileText, message: "the second commit", in: directory)
        try runGit(["checkout", "--quiet", "--detach", "HEAD"], in: directory)
    }

    /// Adds a comment line at the end of the Swift source file
    /// ``sourceFileName`` in the work tree `directory`, and does not stage
    /// the change.
    ///
    /// - Parameter directory: The work tree of a repository that
    ///   ``makeDetachedRepository(in:branch:)`` made.
    /// - Throws: Whatever the file write throws.
    static func appendCommentLine(in directory: URL) throws {
        try (sourceFileText + appendedCommentLine).write(
            to: directory.appendingPathComponent(sourceFileName), atomically: true, encoding: .utf8)
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

    /// Invokes the mounted `tools.git.changes` verb of `registry` and
    /// decodes the wire result.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose changes verb to invoke.
    ///   - arguments: The string arguments of the verb, by name: `branch`,
    ///     `range`, or none.
    /// - Returns: The decoded wire result.
    /// - Throws: Whatever the invocation or the decode throws.
    static func invokeChanges(
        in registry: MultiTool.Registry, arguments: [String: String]
    ) async throws -> ChangesVerbResult {
        try await FilesVerbSupport.invoke(try #require(registry.tools[changesVerbPath]), arguments: arguments)
    }

    /// Invokes the mounted `tools.git.diff` verb of `registry` in the file
    /// mode, and decodes the wire result.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose diff verb to invoke.
    ///   - left: The old side: a path, or `path@ref`.
    ///   - right: The new side: a path, or `path@ref`.
    /// - Returns: The decoded wire result.
    /// - Throws: Whatever the invocation or the decode throws.
    static func invokeDiff(
        in registry: MultiTool.Registry, left: String, right: String
    ) async throws -> DiffVerbResult {
        try await FilesVerbSupport.invoke(
            try #require(registry.tools[diffVerbPath]), arguments: ["left": left, "right": right])
    }

    /// Writes `text` to the file `name` in `directory`, stages it, and
    /// commits it with `message`.
    ///
    /// - Parameters:
    ///   - name: The name of the file, relative to the work tree.
    ///   - text: The text of the file.
    ///   - message: The message of the commit.
    ///   - directory: The work tree of the repository.
    /// - Throws: Whatever the file write or a git command throws, and an
    ///   expectation failure when a git command exits with an error.
    private static func commitFile(named name: String, text: String, message: String, in directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try runGit(["add", name], in: directory)
        try runGit(commitConfiguration + ["commit", "--quiet", "--no-verify", "-m", message], in: directory)
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

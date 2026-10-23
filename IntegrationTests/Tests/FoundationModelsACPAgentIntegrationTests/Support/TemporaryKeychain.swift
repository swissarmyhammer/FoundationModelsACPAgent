// `TemporaryKeychain` — a Keychain file of one test's own.
//
// The self-hosted CI runner's login Keychain is locked, so a test that adds an
// item to it fails with `errSecInteractionNotAllowed` (-25308). A test that
// needs a real Keychain makes its own instead: a new file in a new temporary
// folder, under a password nobody else knows, unlocked, and with no auto-lock.
//
// Each step runs `security(1)`, the system's own Keychain tool, and never a
// deprecated `SecKeychain` call. `security create-keychain` writes the file
// and leaves the user's Keychain search list as it stands, so the test never
// touches the login Keychain or the search list. `delete()` removes the
// Keychain and its folder.

import Foundation

/// A Keychain file in a temporary folder of its own, for one test.
struct TemporaryKeychain {
    /// Why a `security(1)` step failed.
    struct SecurityFailure: Error, CustomStringConvertible {
        /// The subcommand that failed, such as `create-keychain`. The
        /// arguments are left out, because one of them is the password.
        let subcommand: String

        /// The exit status of `security`.
        let status: Int32

        /// What `security` wrote.
        let output: String

        /// The subcommand, the status and the output.
        var description: String {
            "security \(subcommand) exited with status \(status): \(output)"
        }
    }

    /// The absolute path of `security(1)`.
    private static let securityPath = "/usr/bin/security"

    /// The prefix of the name of the temporary folder of each Keychain.
    private static let folderPrefix = "acp-agent-test-keychain-"

    /// The file name of the Keychain in its folder.
    private static let fileName = "test.keychain-db"

    /// The temporary folder that holds the Keychain file and nothing else.
    let folder: URL

    /// The Keychain file.
    let file: URL

    /// Makes a new Keychain file in a new temporary folder: under a random
    /// password, unlocked, and with no auto-lock.
    ///
    /// - Returns: The Keychain.
    /// - Throws: The folder error, or the error of a `security` step (see
    ///   ``runSecurity(_:)``). The folder is removed when a step fails.
    static func make() async throws -> TemporaryKeychain {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keychain = TemporaryKeychain(folder: folder, file: folder.appendingPathComponent(fileName))
        do {
            try await keychain.createUnlockedWithNoAutoLock()
        } catch {
            // The step's own failure is the error the test reports. A failed
            // removal of the folder would only hide it.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return keychain
    }

    /// The user's Keychain search list, as `security list-keychains` writes
    /// it. A test compares it before and after, to prove the Keychain never
    /// joined it.
    ///
    /// - Returns: The text of the list.
    /// - Throws: The error of ``runSecurity(_:)``.
    static func userSearchList() async throws -> String {
        try await runSecurity(["list-keychains", "-d", "user"])
    }

    /// Deletes the Keychain, then its folder.
    ///
    /// - Throws: The error of ``runSecurity(_:)``, or the folder error.
    func delete() async throws {
        try await Self.runSecurity(["delete-keychain", file.path])
        try FileManager.default.removeItem(at: folder)
    }

    /// Creates the Keychain file under a random password, unlocks it, and
    /// sets no lock timeout and no lock on sleep. The password is used here
    /// and then dropped: nothing needs it again.
    ///
    /// - Throws: The error of ``runSecurity(_:)``.
    private func createUnlockedWithNoAutoLock() async throws {
        let password = UUID().uuidString
        try await Self.runSecurity(["create-keychain", "-p", password, file.path])
        try await Self.runSecurity(["unlock-keychain", "-p", password, file.path])
        // With no `-l`, `-u` or `-t`, the Keychain has no timeout and does not
        // lock on sleep.
        try await Self.runSecurity(["set-keychain-settings", file.path])
    }

    /// Runs `security` with `arguments`, with no shell between.
    ///
    /// - Parameter arguments: The subcommand, then its arguments.
    /// - Returns: What `security` wrote, to its output and its error output.
    /// - Throws: The run error (see ``CapturedProcessRun``), or a
    ///   ``SecurityFailure`` when `security` exits with a status other than
    ///   zero.
    @discardableResult
    private static func runSecurity(_ arguments: [String]) async throws -> String {
        let security = try await CapturedProcessRun.run(
            toolAt: securityPath, arguments: arguments, errorOutput: .mergedIntoOutput)
        let text = String(decoding: security.standardOutput, as: UTF8.self)
        guard security.exitCode == 0 else {
            throw SecurityFailure(
                subcommand: arguments.first ?? "", status: security.exitCode, output: text)
        }
        return text
    }
}

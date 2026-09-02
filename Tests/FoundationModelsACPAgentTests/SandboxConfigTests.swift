import Foundation
import FoundationModelsACPAgent
import FoundationModelsMultitool
import Testing

/// The `sandbox:` config section (plan.md §11.7): the decode of
/// `extraWritePaths`, the session-root-set default for the writable roots,
/// and the `realpath(3)` resolution the options initializer applies.
@Suite struct SandboxConfigTests {
    /// A throwaway directory under `/private/tmp`, labeled with this
    /// suite's name and the directory's role.
    ///
    /// - Parameter name: The directory's role.
    /// - Returns: The created directory.
    private static func makeResolvedDirectory(named name: String) -> URL {
        FoundationModelsACPAgentTests.makeResolvedDirectory(label: "SandboxConfigTests-\(name)")
    }

    /// With no `sandbox:` section, the writable roots equal the session
    /// root set — the working directory first, then the additional roots —
    /// and there is no extra write path.
    @Test func defaultWritableRootsAreTheSessionRootSet() throws {
        let workingDirectory = Self.makeResolvedDirectory(named: "cwd")
        let additionalRoot = Self.makeResolvedDirectory(named: "extra")

        let options = SandboxConfiguration().sandboxOptions(
            workingDirectory: workingDirectory, additionalRoots: [additionalRoot])

        #expect(options.writableRoots == [workingDirectory.path, additionalRoot.path])
        #expect(options.extraWritePaths.isEmpty)
    }

    /// A configured `extraWritePaths` entry reaches the built options, and
    /// the writable roots stay the session root set.
    @Test func extraWritePathsReachTheBuiltOptions() throws {
        let workingDirectory = Self.makeResolvedDirectory(named: "cwd")
        let extraWritePath = Self.makeResolvedDirectory(named: "cache")
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            """
            sandbox:
              extraWritePaths:
                - \(extraWritePath.path)
            """)

        let options = loaded.configuration.sandbox.sandboxOptions(
            workingDirectory: workingDirectory)

        #expect(options.writableRoots == [workingDirectory.path])
        #expect(options.extraWritePaths == [extraWritePath.path])
    }

    /// A writable root given as a `/tmp` symlink path arrives resolved with
    /// the `/private` prefix kept: the options build through
    /// `SeatbeltSandbox.Options.init`, which runs `realpath(3)` over both
    /// lists (plan.md §2.5).
    @Test func symlinkedRootArrivesRealpathResolved() throws {
        let resolved = Self.makeResolvedDirectory(named: "linked")
        let symlinked = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(resolved.lastPathComponent, isDirectory: true)

        let options = SandboxConfiguration().sandboxOptions(workingDirectory: symlinked)

        #expect(options.writableRoots == [resolved.path])
    }

    /// An unknown key inside the `sandbox:` section is an error that names
    /// the section and the key: the section holds `extraWritePaths` only.
    @Test func unknownSandboxKeyIsAnError() throws {
        let fixture = ConfigurationLoaderTests.Fixture()

        #expect(throws: ConfigurationError.unknownKey(section: "sandbox", key: "extraReadPaths")) {
            try fixture.loadProjectConfig(
                """
                sandbox:
                  extraReadPaths:
                    - /var/data
                """)
        }
    }
}

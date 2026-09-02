import Foundation
import FoundationModels
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The sandbox composition (plan.md §11.7): the seatbelt sandbox over the
/// session root set is the only gate on the shell capability.
///
/// The proof is filesystem truth: a confined write inside the root set
/// lands on disk, a confined write outside it does not, and a failed
/// preflight refuses the command before anything spawns. The empty-root-set
/// case and the `/private` symlink case are regression tests against the
/// two silent widenings the upstream types permit.
@Suite struct SandboxCompositionTests {
    /// The surface path of the shell execute verb.
    private static let executeVerbPath = "shell.execute"

    /// The marker a scripted preflight failure carries, so an assertion
    /// can find the reason in the tool answer.
    private static let preflightFailureMarker = "injected preflight failure"

    /// The exit code the injected preflight refusal reports. The value
    /// mirrors the wrapper's own profile-compilation failure code.
    private static let preflightFailureExitCode: Int32 = 65

    // MARK: - Fixtures

    /// A throwaway directory under `/private/tmp`, labeled with this
    /// suite's name and the directory's role.
    ///
    /// - Parameter name: The directory's role.
    /// - Returns: The created directory.
    private static func makeResolvedDirectory(named name: String) -> URL {
        FoundationModelsACPAgentTests.makeResolvedDirectory(
            label: "SandboxCompositionTests-\(name)")
    }

    /// Builds the registry the catalog composes over `workingDirectory`,
    /// with the shell store redirected into a throwaway directory.
    ///
    /// - Parameter workingDirectory: The session working directory — the
    ///   root set's first member.
    /// - Returns: The built registry.
    /// - Throws: Whatever the catalog build throws.
    private static func makeRegistry(workingDirectory: URL) async throws -> MultiTool.Registry {
        var configuration = AgentConfiguration()
        configuration.tools.shell = .enabled(
            ShellToolOptions(storeDirectory: makeResolvedDirectory(named: "store")))
        let context = CatalogContext(
            workingDirectory: workingDirectory,
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(named: "cache")))
        return try await ToolCatalog.makeRegistry(context: context).registry
    }

    /// Invokes `tools.shell.execute` and returns the rendered report.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose execute verb to invoke.
    ///   - command: The shell command to run.
    ///   - workingDirectory: The directory the command runs in.
    /// - Returns: The verb's rendered answer.
    /// - Throws: Whatever the invocation throws.
    private static func invokeExecute(
        in registry: MultiTool.Registry, command: String, workingDirectory: URL
    ) async throws -> String {
        let tool = try #require(registry.tools[executeVerbPath])
        let argumentsJSON = try executeArgumentsJSON(
            command: command, workingDirectory: workingDirectory)
        let output = try await ToolInvoker.invoke(
            tool, content: try GeneratedContent(json: argumentsJSON))
        return try #require(output as? String)
    }

    /// The wire JSON of one execute call.
    ///
    /// - Parameters:
    ///   - command: The shell command to run.
    ///   - workingDirectory: The directory the command runs in.
    /// - Returns: The arguments as JSON text.
    /// - Throws: Whatever the encode throws.
    private static func executeArgumentsJSON(
        command: String, workingDirectory: URL
    ) throws -> String {
        let arguments = ["command": command, "workingDirectory": workingDirectory.path]
        return String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
    }

    /// A `CommandSandbox` whose preflight always refuses, so a test proves
    /// a failed preflight never reaches a spawn. `wrap` throws the same
    /// refusal: a caller that skipped the preflight still cannot spawn.
    private struct RefusingPreflightSandbox: CommandSandbox {
        /// The refusal both members throw.
        let refusal = SeatbeltSandboxError.profileRejected(
            exitCode: SandboxCompositionTests.preflightFailureExitCode,
            stderr: SandboxCompositionTests.preflightFailureMarker)

        func preflight(workingDirectory: String, temporaryDirectory: String) async throws {
            throw refusal
        }

        func wrap(
            shellPath: String,
            shellArguments: [String],
            workingDirectory: String,
            temporaryDirectory: String
        ) throws -> SandboxedInvocation {
            throw refusal
        }
    }

    // MARK: - Filesystem truth

    /// A confined write inside the root set succeeds: the file is on disk
    /// afterwards, with the written content.
    @Test(.timeLimit(.minutes(1)))
    func aWriteInsideTheRootSetLandsOnDisk() async throws {
        let root = Self.makeResolvedDirectory(named: "write-in")
        let registry = try await Self.makeRegistry(workingDirectory: root)

        _ = try await Self.invokeExecute(
            in: registry, command: "printf confined > inside.txt", workingDirectory: root)

        let written = root.appendingPathComponent("inside.txt")
        #expect(try String(contentsOf: written, encoding: .utf8) == "confined")
    }

    /// A confined write outside the root set fails: the command runs — the
    /// answer is a run report, not a refusal — and the file is not on disk
    /// afterwards, because the kernel denied the write.
    @Test(.timeLimit(.minutes(1)))
    func aWriteOutsideTheRootSetNeverLands() async throws {
        let root = Self.makeResolvedDirectory(named: "write-out-root")
        let outside = Self.makeResolvedDirectory(named: "write-out-target")
        let registry = try await Self.makeRegistry(workingDirectory: root)
        let escaped = outside.appendingPathComponent("escaped.txt")

        let answer = try await Self.invokeExecute(
            in: registry,
            command: "printf escaped > '\(escaped.path)'",
            workingDirectory: root)

        #expect(!answer.contains("NOT run"))
        #expect(answer.contains("commandID"))
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    // MARK: - The empty root set

    /// An empty root set is refused with this package's own error, before
    /// `SeatbeltSandbox.Options` is constructed. The upstream initializer
    /// replaces an empty list with the process working directory — the
    /// widest grant — so the guard must come first (plan.md §11.7).
    @Test func anEmptyRootSetIsRefusedBeforeOptionsExist() {
        #expect(throws: SandboxCompositionError.emptyRootSet) {
            _ = try SandboxComposition.makeShellSandbox(
                rootSet: [], configuration: SandboxConfiguration())
        }
    }

    // MARK: - The preflight refusal

    /// A command whose preflight throws never spawns: the answer carries
    /// the reason, and the file the command names is not on disk. The
    /// injected sandbox goes through the same composition seam the
    /// production sandbox does.
    @Test(.timeLimit(.minutes(1)))
    func aThrowingPreflightRefusesTheCommandWithTheReason() async throws {
        let root = Self.makeResolvedDirectory(named: "preflight")
        let builder = MultiTool.Builder()
        try SandboxComposition.composeShell(
            into: builder,
            options: ShellToolOptions(storeDirectory: Self.makeResolvedDirectory(named: "store")),
            sandbox: RefusingPreflightSandbox())
        let registry = try builder.buildRegistry()

        let answer = try await Self.invokeExecute(
            in: registry, command: "printf never > sentinel.txt", workingDirectory: root)

        #expect(answer.contains(Self.preflightFailureMarker))
        #expect(answer.contains("NOT run"))
        let sentinel = root.appendingPathComponent("sentinel.txt")
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    // MARK: - The `/private` symlink regression

    /// A root given through a `/tmp` symlink path arrives in the built
    /// sandbox `realpath(3)`-resolved, with the `/private` prefix kept
    /// (plan.md §2.5).
    @Test func aSymlinkedRootArrivesResolvedInTheBuiltSandbox() throws {
        let resolved = Self.makeResolvedDirectory(named: "linked")
        let symlinked = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(resolved.lastPathComponent, isDirectory: true)

        let sandbox = try SandboxComposition.makeShellSandbox(
            rootSet: [symlinked], configuration: SandboxConfiguration())

        #expect(sandbox.options.writableRoots == [resolved.path])
    }

    /// A writable root given through a symlinked `/tmp` path confines
    /// correctly end to end: a write into that root lands on disk, under
    /// the resolved `/private` location.
    @Test(.timeLimit(.minutes(1)))
    func aSymlinkedRootConfinesAWriteEndToEnd() async throws {
        let resolved = Self.makeResolvedDirectory(named: "linked-run")
        let symlinked = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(resolved.lastPathComponent, isDirectory: true)
        let registry = try await Self.makeRegistry(workingDirectory: symlinked)

        _ = try await Self.invokeExecute(
            in: registry, command: "printf linked > linked.txt", workingDirectory: symlinked)

        let written = resolved.appendingPathComponent("linked.txt")
        #expect(try String(contentsOf: written, encoding: .utf8) == "linked")
    }

    // MARK: - No permission request

    /// A scripted tool turn that runs a confined shell command sends no
    /// `session/request_permission` to the client: the collector holds no
    /// notification, and no session has a pending permission request. The
    /// sandbox is the only gate (plan.md §11.7).
    @Test(.timeLimit(.minutes(1)))
    func aScriptedToolTurnSendsNoPermissionRequest() async throws {
        let harness = try await AgentClientHarness.makeRecording()
        let collector = try #require(harness.collector)
        _ = try await harness.connection.initialize(
            AgentClientHarness.makeInitializeRequest())

        let root = Self.makeResolvedDirectory(named: "turn")
        let registry = try await Self.makeRegistry(workingDirectory: root)
        let tool = try #require(registry.tools[Self.executeVerbPath])
        let argumentsJSON = try Self.executeArgumentsJSON(
            command: "printf turn > turn.txt", workingDirectory: root)
        let backend = ScriptedLLMContainer(
            script: [.toolCall(name: tool.name, argumentsJSON: argumentsJSON), .endTurn]
        ).makeSession(instructions: nil, tools: [tool])

        _ = try await backend.respond(to: "run the command", maxTokens: nil)

        let written = root.appendingPathComponent("turn.txt")
        #expect(try String(contentsOf: written, encoding: .utf8) == "turn")
        #expect(await collector.updates.isEmpty)
        let pendingPermissionCounts = await MainActor.run {
            harness.client.sessions.values.map(\.pendingPermissionRequests.count)
        }
        #expect(pendingPermissionCounts.allSatisfy { $0 == 0 })
        await harness.close()
    }

    // MARK: - The stated limit

    /// The README states the limit in the sandbox's own words: writing and
    /// deleting are bounded, reads are free, and the network is open.
    @Test func theReadmeStatesTheReadAndNetworkLimit() throws {
        let readme = try String(
            contentsOf: DocumentationSyncTests.readmeURL, encoding: .utf8)

        #expect(readme.contains(SandboxComposition.statedLimit))
    }
}

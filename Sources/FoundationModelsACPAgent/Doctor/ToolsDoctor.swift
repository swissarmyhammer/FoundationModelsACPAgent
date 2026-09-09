import Foundation
import FoundationModelsExtras
import FoundationModelsMultitool

/// The `doctor` component of the sandbox and the tools (cli-plan.md §5.12,
/// the Sandbox and Tools rows): the seatbelt sandbox starts, each
/// `sandbox.extraWritePaths` entry is on disk, the shell store directory
/// can be written, and each configured MCP server answers.
///
/// The component takes the resolved configuration and an injected
/// ``ToolsProber``, so a unit test starts no confined command and no MCP
/// server. Every prober call runs under ``probeTimeoutSeconds``, so one
/// server that stopped answering cannot hold the whole report.
///
/// Nothing here throws. A probe that failed is one finding with the
/// ``HealthStatus/error`` status, and a probe that did not answer is one
/// with the ``HealthStatus/warning`` status, so one broken tool never stops
/// the other checks.
///
/// The `files:` and `skills:` sections are not read here. The skills stack
/// is a component of its own, and the files capability reaches only the
/// session root set, which the sandbox row already covers.
public struct ToolsDoctor: Doctorable {
    // MARK: - Constants

    /// The group every finding of this component belongs to.
    public static let category = "tools"

    /// How long one prober call may take, in seconds.
    ///
    /// A probe starts a subprocess or asks a network endpoint, so it is
    /// never instant; and `doctor` must print its table even when one of
    /// them stops answering. This is the bound both statements meet.
    public static let probeTimeoutSeconds = 5.0

    /// The check that states whether the sandbox starts.
    private static let sandboxCheckName = "the seatbelt sandbox"

    /// What the sandbox check says when the confined command ran.
    private static let sandboxPassed = "a confined command ran under the sandbox"

    /// What the sandbox check calls the thing it probed.
    private static let sandboxSubject = "the seatbelt sandbox"

    /// The prefix of the check that states one extra write path.
    private static let extraWritePathPrefix = "the extra write path"

    /// The check that states the shell store directory.
    private static let storeCheckName = "the shell store directory"

    /// What stands at the store path, for the message of a path that a file
    /// already blocks.
    private static let storeSubject = "shell store directory"

    /// The check that states the shell tool is off.
    private static let shellToolCheckName = "the shell tool"

    /// The check that states the mcp tool is off.
    private static let mcpToolCheckName = "the mcp tool"

    /// The prefix of the check that states one configured MCP server.
    private static let mcpServerPrefix = "the mcp server"

    /// The store directory the shell capability makes when the config names
    /// none: `.shell` under the working directory.
    private static let defaultStoreDirectoryName = ".shell"

    /// The dotted key path of the extra write paths a fix names.
    private static let extraWritePathsKey =
        AgentConfiguration.CodingKeys.sandbox.stringValue
        + LoadedConfiguration.keyPathSeparator
        + SandboxConfiguration.CodingKeys.extraWritePaths.stringValue

    /// The dotted key path of the sandbox section a fix names.
    private static let sandboxKey = AgentConfiguration.CodingKeys.sandbox.stringValue

    /// The dotted key path of the shell section a fix names.
    private static let shellKey =
        AgentConfiguration.CodingKeys.tools.stringValue
        + LoadedConfiguration.keyPathSeparator
        + ToolsConfiguration.CodingKeys.shell.stringValue

    /// The dotted key path of the store directory a fix names.
    private static let storeDirectoryKey =
        shellKey
        + LoadedConfiguration.keyPathSeparator
        + ShellToolOptions.CodingKeys.storeDirectory.stringValue

    /// The dotted key path of the mcp section a fix names.
    private static let mcpKey =
        AgentConfiguration.CodingKeys.tools.stringValue
        + LoadedConfiguration.keyPathSeparator
        + ToolsConfiguration.CodingKeys.mcp.stringValue

    // MARK: - Stored state

    /// The resolved configuration, which names the sandbox grants and the
    /// tool roster.
    private let configuration: AgentConfiguration

    /// The directory `--cwd` names. It is the first writable root of the
    /// sandbox, and it roots the default shell store.
    private let workingDirectory: URL

    /// How the checks reach the world.
    private let prober: any ToolsProber

    /// How long one prober call may take, in seconds.
    public let timeoutSeconds: Double

    // MARK: - Doctorable

    /// What this component is called in the doctor report.
    public let doctorName = ToolsDoctor.category

    /// The group its findings belong to.
    public let doctorCategory = ToolsDoctor.category

    /// Makes the component over one resolved configuration and one prober.
    ///
    /// - Parameters:
    ///   - configuration: The resolved configuration.
    ///   - workingDirectory: The directory `--cwd` names.
    ///   - prober: How the checks reach the world.
    ///   - timeoutSeconds: How long one prober call may take. The default
    ///     is ``probeTimeoutSeconds``.
    public init(
        configuration: AgentConfiguration, workingDirectory: URL, prober: any ToolsProber,
        timeoutSeconds: Double = ToolsDoctor.probeTimeoutSeconds
    ) {
        self.configuration = configuration
        self.workingDirectory = workingDirectory
        self.prober = prober
        self.timeoutSeconds = timeoutSeconds
    }

    /// Reports the sandbox, then one finding per extra write path, then the
    /// shell, then the MCP servers.
    ///
    /// - Returns: The findings, in that order.
    public func runHealthChecks() async -> [HealthCheck] {
        await [sandboxCheck()]
            + configuration.sandbox.extraWritePaths.map(Self.check(ofExtraWritePath:))
            + [shellCheck()]
            + mcpChecks()
    }

    // MARK: - The sandbox

    /// The finding of the sandbox itself: one trivial confined command,
    /// through the prober.
    ///
    /// - Returns: A pass, or the failure the prober reported.
    private func sandboxCheck() async -> HealthCheck {
        let options = configuration.sandbox.sandboxOptions(workingDirectory: workingDirectory)
        let outcome = await probe { await prober.startSandbox(options: options) }
        return finding(
            of: outcome, name: Self.sandboxCheckName, passed: Self.sandboxPassed,
            subject: Self.sandboxSubject, fix: Self.sandboxFix)
    }

    /// The fix of a sandbox that does not start: the grants are what a
    /// person controls.
    private static let sandboxFix =
        "check the \(sandboxKey) section of \(ConfigurationLoader.configFileName), "
        + "and that this host can run a confined command"

    /// The finding of one extra write path: whether it is on disk.
    ///
    /// A grant of a path that is not there widens nothing, and the shell
    /// still runs, so a missing entry is a warning and not a failure.
    ///
    /// - Parameter path: The configured path.
    /// - Returns: The finding of that path.
    private static func check(ofExtraWritePath path: String) -> HealthCheck {
        let name = "\(extraWritePathPrefix) \(path)"
        guard FileManager.default.fileExists(atPath: path) else {
            return .warning(
                name: name,
                message: "\(path) is not on disk, so the sandbox grants nothing there",
                fix: "create \(path), or remove it from \(extraWritePathsKey) in "
                    + ConfigurationLoader.configFileName,
                category: category)
        }
        return .ok(name: name, message: "\(path) is on disk", category: category)
    }

    // MARK: - The shell

    /// The finding of the shell section: the store directory when the tool
    /// is on, and one row that says disabled when it is off.
    ///
    /// - Returns: That one finding.
    private func shellCheck() -> HealthCheck {
        switch configuration.tools.shell {
        case .disabled:
            return DisabledSectionCheck.check(
                name: Self.shellToolCheckName, key: Self.shellKey, category: Self.category)
        case .enabled(let options):
            return WritableDirectoryCheck.check(
                of: options.storeDirectory ?? defaultStoreDirectory,
                name: Self.storeCheckName, subject: Self.storeSubject, category: Self.category,
                fix: Self.storeFix(naming:))
        }
    }

    /// The store directory the shell capability makes when
    /// `tools.shell.storeDirectory` names none.
    private var defaultStoreDirectory: URL {
        workingDirectory.appendingPathComponent(
            Self.defaultStoreDirectoryName, isDirectory: true)
    }

    /// The fix of a store directory that cannot be used: make the directory
    /// writable, or point the configuration key somewhere else.
    ///
    /// - Parameter directory: The directory that stands in the way.
    /// - Returns: The fix text.
    private static func storeFix(naming directory: URL) -> String {
        "make \(directory.path) writable, or set \(storeDirectoryKey) in "
            + "\(ConfigurationLoader.configFileName) to a directory that can be written"
    }

    // MARK: - The MCP servers

    /// The findings of the `mcp:` section: one per configured server, or
    /// one row that says disabled.
    ///
    /// The servers are probed together, so one slow server does not add its
    /// wait to the next one. The findings come back in document order.
    ///
    /// - Returns: The findings, in document order.
    private func mcpChecks() async -> [HealthCheck] {
        guard case .enabled(let servers) = configuration.tools.mcp else {
            return [
                DisabledSectionCheck.check(
                    name: Self.mcpToolCheckName, key: Self.mcpKey, category: Self.category)
            ]
        }
        return await withTaskGroup(of: (Int, HealthCheck).self) { group in
            for (position, entry) in servers.enumerated() {
                group.addTask { (position, await self.mcpCheck(of: entry)) }
            }
            var byPosition: [Int: HealthCheck] = [:]
            for await (position, check) in group {
                byPosition[position] = check
            }
            return servers.indices.compactMap { byPosition[$0] }
        }
    }

    /// The finding of one configured MCP server: the prober starts it and
    /// stops it again.
    ///
    /// - Parameter entry: The server entry to probe.
    /// - Returns: A pass, or the failure the prober reported.
    private func mcpCheck(of entry: MCPServerConfiguration) async -> HealthCheck {
        let subject = Self.subject(of: entry)
        let outcome = await probe { await prober.startMCPServer(entry) }
        return finding(
            of: outcome, name: "\(Self.mcpServerPrefix) \(entry.name)",
            passed: "\(subject) answered", subject: subject, fix: Self.fix(naming: entry))
    }

    /// One server entry as a person reads it: the name it mounts under, and
    /// the command or the URL it is reached at.
    ///
    /// - Parameter entry: The server entry to describe.
    /// - Returns: The noun phrase a message carries.
    private static func subject(of entry: MCPServerConfiguration) -> String {
        switch entry.transport {
        case .stdio(let command, _, _):
            return "mcp server \"\(entry.name)\" (command \(command))"
        case .http(let url, _):
            return "mcp server \"\(entry.name)\" (url \(url))"
        }
    }

    /// The fix of a server that cannot be reached: its own entry is what a
    /// person edits.
    ///
    /// - Parameter entry: The server entry that did not answer.
    /// - Returns: The fix text.
    private static func fix(naming entry: MCPServerConfiguration) -> String {
        "check the \"\(entry.name)\" entry under \(mcpKey) in "
            + ConfigurationLoader.configFileName
    }

    // MARK: - The shared shapes

    /// The finding one probe gives.
    ///
    /// - Parameters:
    ///   - outcome: What the probe gave.
    ///   - name: What the finding is called in the report.
    ///   - passed: The message of a probe that answered.
    ///   - subject: What was probed, as a noun phrase.
    ///   - fix: What to do about a probe that did not pass.
    /// - Returns: The finding.
    private func finding(
        of outcome: ProbeOutcome, name: String, passed: String, subject: String, fix: String
    ) -> HealthCheck {
        switch outcome {
        case .answered:
            return .ok(name: name, message: passed, category: Self.category)
        case .failed(let reason):
            return .error(
                name: name, message: "\(subject) did not pass: \(reason)", fix: fix,
                category: Self.category)
        case .timedOut:
            return .warning(
                name: name,
                message: "\(subject) did not answer in \(timeoutSeconds) seconds",
                fix: fix, category: Self.category)
        }
    }

    /// Runs one prober call under ``timeoutSeconds``.
    ///
    /// - Parameter call: The prober call to run.
    /// - Returns: What the call gave, or ``ProbeOutcome/timedOut``.
    private func probe(
        _ call: @escaping @Sendable () async -> ProbeOutcome
    ) async -> ProbeOutcome {
        await ProbeTimeout.run(seconds: timeoutSeconds, timedOut: .timedOut, probe: call)
    }
}

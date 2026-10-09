import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// `ToolsDoctor` (cli-plan.md §5.12, the Sandbox and Tools rows): the
/// seatbelt sandbox starts, each `sandbox.extraWritePaths` entry is on
/// disk, the shell store directory can be written, and each configured MCP
/// server answers.
///
/// Every test drives the component over a scripted ``StubToolsProber``, so
/// no test starts a confined command and no test starts an MCP server. The
/// findings are therefore the same on any machine and in CI.
struct ToolsDoctorTests {
    // MARK: - Constants

    /// The number of findings a test that expects exactly one gets.
    private static let oneFinding = 1

    /// The number of rows a roster with the shell tool off reports: the
    /// sandbox row, the shell row, the web row, the git row and the
    /// environment row. The `mcp:` default names no server, so it adds none.
    private static let disabledShellRowCount = 5

    /// The name of the web row.
    private static let webRowName = "the web tool"

    /// The configuration key a disabled web row names.
    private static let webEnabledKey = "tools.web.enabled"

    /// The name of the git row.
    private static let gitRowName = "the git tool"

    /// The configuration key a disabled git row names.
    private static let gitEnabledKey = "tools.git.enabled"

    /// The name of the environment row.
    private static let environmentRowName = "the environment tool"

    /// The configuration key that the environment row names: the key that
    /// turns the tool off.
    private static let environmentEnabledKey = "tools.environment.enabled"

    /// The word of the note of the environment row that states the secret
    /// risk.
    private static let secretWord = "secret"

    /// The timeout a test that proves the timeout injects, in seconds. It
    /// is short, so the test does not wait long for the timeout to fire.
    private static let shortTimeoutSeconds = 0.2

    /// The word a disabled tool section reports, so a person sees why the
    /// tool is absent.
    private static let disabledWord = "disabled"

    /// The name of the configured MCP server the tests probe.
    private static let serverName = "notes"

    /// A command no host has, which stands for a server command the prober
    /// reports absent.
    private static let missingCommand = "/nowhere/mcp-notes-server"

    /// The reason the prober gives for a command that is not there.
    private static let absentReason = "no such file or directory"

    /// The reason the prober gives for a sandbox that does not start.
    private static let sandboxRefusedReason = "sandbox-exec refused the profile"

    /// The permissions of a directory that can be read but not written.
    private static let readOnlyPermissions = NSNumber(value: 0o500)

    /// The configuration key a store-directory fix names.
    private static let storeDirectoryKey = "tools.shell.storeDirectory"

    /// The configuration key an extra-write-path fix names.
    private static let extraWritePathsKey = "sandbox.extraWritePaths"

    // MARK: - Helpers

    /// The component over one configuration and one working directory.
    ///
    /// - Parameters:
    ///   - configuration: The resolved configuration the checks read.
    ///   - workingDirectory: The directory `--cwd` names.
    ///   - prober: The scripted prober.
    ///   - timeoutSeconds: How long one prober call may take.
    ///   - environment: The process environment the web row reads the API
    ///     keys from. The default is empty, thus no test reads a key of the
    ///     machine that runs it.
    /// - Returns: The component.
    private static func doctor(
        configuration: AgentConfiguration,
        workingDirectory: URL,
        prober: StubToolsProber = StubToolsProber(),
        timeoutSeconds: Double = ToolsDoctor.probeTimeoutSeconds,
        environment: [String: String] = [:]
    ) -> ToolsDoctor {
        ToolsDoctor(
            configuration: configuration, workingDirectory: workingDirectory, prober: prober,
            timeoutSeconds: timeoutSeconds, environment: environment)
    }

    /// The web row of `checks`.
    ///
    /// - Parameter checks: The findings of one run.
    /// - Returns: The one finding whose name is ``webRowName``.
    /// - Throws: When no finding has that name.
    private static func webRow(in checks: [HealthCheck]) throws -> HealthCheck {
        try row(named: webRowName, in: checks)
    }

    /// The row of `checks` whose name is `name`.
    ///
    /// - Parameters:
    ///   - name: The name of the row.
    ///   - checks: The findings of one run.
    /// - Returns: The first finding with that name.
    /// - Throws: When no finding has that name.
    private static func row(named name: String, in checks: [HealthCheck]) throws -> HealthCheck {
        try #require(checks.first { $0.name == name })
    }

    /// The findings of `checks` that carry `status`.
    ///
    /// - Parameters:
    ///   - status: The status to keep.
    ///   - checks: The findings to filter.
    /// - Returns: The findings that carry `status`.
    private static func findings(
        _ status: HealthStatus, in checks: [HealthCheck]
    ) -> [HealthCheck] {
        checks.filter { $0.status == status }
    }

    /// A configuration whose `mcp:` section names one stdio server called
    /// ``serverName`` at ``missingCommand``.
    ///
    /// - Returns: The configuration.
    private static func configurationWithOneServer() -> AgentConfiguration {
        var configuration = AgentConfiguration()
        configuration.tools.mcp = .enabled(servers: [
            MCPServerConfiguration(
                name: serverName,
                transport: .stdio(command: missingCommand, args: [], env: [:]))
        ])
        return configuration
    }

    // MARK: - The sandbox

    /// A prober that answers everywhere, over the default roster, gives
    /// rows and every one of them passes. The fixture decides the answer,
    /// so the result is the same on any machine.
    @Test func aProberThatAnswersGivesOnlyPassingRows() async {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-pass")

        let checks = await Self.doctor(
            configuration: AgentConfiguration(), workingDirectory: workspace
        ).runHealthChecks()

        #expect(!checks.isEmpty)
        #expect(checks.allSatisfy { $0.status == .ok })
    }

    /// A sandbox that does not start is one `.error` that carries the
    /// reason the prober gave.
    @Test func aSandboxThatDoesNotStartGivesOneErrorWithTheReason() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-sandbox")
        let prober = StubToolsProber(sandbox: .failed(reason: Self.sandboxRefusedReason))

        let checks = await Self.doctor(
            configuration: AgentConfiguration(), workingDirectory: workspace, prober: prober
        ).runHealthChecks()

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(Self.sandboxRefusedReason))
        #expect(failure.fix != nil)
    }

    // MARK: - The extra write paths

    /// An `extraWritePaths` entry that is not on disk is one `.warning`
    /// that names it, and an entry that is on disk passes beside it.
    @Test func aMissingExtraWritePathGivesOneWarningThatNamesIt() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-extra")
        let missing = workspace.appendingPathComponent("absent", isDirectory: true)
        var configuration = AgentConfiguration()
        configuration.sandbox.extraWritePaths = [workspace.path, missing.path]

        let checks = await Self.doctor(
            configuration: configuration, workingDirectory: workspace
        ).runHealthChecks()

        let warnings = Self.findings(.warning, in: checks)
        let warning = try #require(warnings.first)
        let fix = try #require(warning.fix)
        #expect(warnings.count == Self.oneFinding)
        #expect(warning.message.contains(missing.path))
        #expect(fix.contains(Self.extraWritePathsKey))
        #expect(Self.findings(.error, in: checks).isEmpty)
    }

    // MARK: - The shell store directory

    /// A store directory under a parent that cannot be written is one
    /// `.error`, and its fix names the `tools.shell.storeDirectory` key.
    @Test func anUnwritableShellStoreGivesAnErrorThatNamesTheKey() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-store")
        let parent = makeResolvedDirectory(label: "ToolsDoctorTests-storeParent")
        let store = parent.appendingPathComponent("shell-store", isDirectory: true)
        var configuration = AgentConfiguration()
        configuration.tools.shell = .enabled(ShellToolOptions(storeDirectory: store))
        try setPermissions(Self.readOnlyPermissions, of: parent)

        let checks = await Self.doctor(
            configuration: configuration, workingDirectory: workspace
        ).runHealthChecks()
        try setPermissions(ownerOnlyPermissions, of: parent)

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        let fix = try #require(failure.fix)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(store.path))
        #expect(fix.contains(Self.storeDirectoryKey))
    }

    /// `tools.shell: false` gives one `.ok` row that says disabled, and no
    /// store-directory check runs: the roster reports the sandbox row, that
    /// one row, the web row, the git row and the environment row, and
    /// nothing else.
    @Test func aDisabledShellSectionSaysDisabledAndChecksNoStore() async {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-shellOff")
        var configuration = AgentConfiguration()
        configuration.tools.shell = .disabled

        let checks = await Self.doctor(
            configuration: configuration, workingDirectory: workspace
        ).runHealthChecks()

        #expect(checks.count == Self.disabledShellRowCount)
        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(checks.contains { $0.message.contains(Self.disabledWord) })
    }

    // MARK: - The web tool

    /// With no key, the web row passes and names the keyless providers in
    /// order. The row sends no request.
    @Test func theWebRowNamesTheKeylessProvidersInOrder() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-webKeyless")

        let checks = await Self.doctor(
            configuration: AgentConfiguration(), workingDirectory: workspace
        ).runHealthChecks()

        let row = try Self.webRow(in: checks)
        #expect(row.status == .ok)
        #expect(row.message.contains("duckDuckGoHTML, braveHTML"))
    }

    /// A key in the environment puts its provider first in the row, and the
    /// row never shows the key value.
    @Test func theWebRowNamesAKeyedProviderAndNoKeyValue() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-webKeyed")
        let keyValue = "doctor-key-value"

        let checks = await Self.doctor(
            configuration: AgentConfiguration(), workingDirectory: workspace,
            environment: ["TAVILY_API_KEY": keyValue]
        ).runHealthChecks()

        let row = try Self.webRow(in: checks)
        #expect(row.message.contains("tavily, duckDuckGoHTML, braveHTML"))
        #expect(!checks.contains { $0.message.contains(keyValue) })
    }

    /// `tools.web.enabled: false` gives one `.ok` row that says disabled
    /// and names the key.
    @Test func aWebSectionThatIsNotEnabledSaysDisabled() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-webOff")
        var configuration = AgentConfiguration()
        configuration.tools.web = .enabled(WebToolOptions(enabled: false))

        let checks = await Self.doctor(
            configuration: configuration, workingDirectory: workspace
        ).runHealthChecks()

        let row = try Self.webRow(in: checks)
        #expect(row.status == .ok)
        #expect(row.message.contains(Self.disabledWord))
        #expect(row.message.contains(Self.webEnabledKey))
    }

    // MARK: - The git tool

    /// With the default configuration, the git row passes and says that the
    /// tool is on.
    @Test func theGitRowSaysOn() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-gitOn")

        let checks = await Self.doctor(
            configuration: AgentConfiguration(), workingDirectory: workspace
        ).runHealthChecks()

        let row = try Self.row(named: Self.gitRowName, in: checks)
        #expect(row.status == .ok)
        #expect(!row.message.contains(Self.disabledWord))
    }

    /// `tools.git: false` and `tools.git.enabled: false` each give one `.ok`
    /// row that says disabled and names the key.
    @Test(arguments: [
        ToolSection<GitToolOptions>.disabled, .enabled(GitToolOptions(enabled: false)),
    ])
    func aGitSectionThatIsOffSaysDisabled(section: ToolSection<GitToolOptions>) async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-gitOff")
        var configuration = AgentConfiguration()
        configuration.tools.git = section

        let checks = await Self.doctor(
            configuration: configuration, workingDirectory: workspace
        ).runHealthChecks()

        let row = try Self.row(named: Self.gitRowName, in: checks)
        #expect(row.status == .ok)
        #expect(row.message.contains(Self.disabledWord))
        #expect(row.message.contains(Self.gitEnabledKey))
    }

    // MARK: - The environment tool

    /// With the default configuration, the environment row passes, says
    /// that the tool is on, and states the secret risk with the key that
    /// turns the tool off. The row never shows the value of a variable.
    @Test func theEnvironmentRowStatesTheSecretRiskAndNoValue() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-environmentOn")
        let secretValue = "environment-secret-value"

        let checks = await Self.doctor(
            configuration: AgentConfiguration(), workingDirectory: workspace,
            environment: ["TAVILY_API_KEY": secretValue]
        ).runHealthChecks()

        let row = try Self.row(named: Self.environmentRowName, in: checks)
        #expect(row.status == .ok)
        #expect(!row.message.contains(Self.disabledWord))
        #expect(row.message.contains(Self.secretWord))
        #expect(row.message.contains(Self.environmentEnabledKey))
        #expect(!checks.contains { $0.message.contains(secretValue) })
    }

    /// `tools.environment: false` and `tools.environment.enabled: false`
    /// each give one `.ok` row that says disabled and names the key.
    @Test(arguments: [
        ToolSection<EnvironmentToolOptions>.disabled,
        .enabled(EnvironmentToolOptions(enabled: false)),
    ])
    func anEnvironmentSectionThatIsOffSaysDisabled(
        section: ToolSection<EnvironmentToolOptions>
    ) async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-environmentOff")
        var configuration = AgentConfiguration()
        configuration.tools.environment = section

        let checks = await Self.doctor(
            configuration: configuration, workingDirectory: workspace
        ).runHealthChecks()

        let row = try Self.row(named: Self.environmentRowName, in: checks)
        #expect(row.status == .ok)
        #expect(row.message.contains(Self.disabledWord))
        #expect(row.message.contains(Self.environmentEnabledKey))
        #expect(!row.message.contains(Self.secretWord))
    }

    // MARK: - The MCP servers

    /// A configured server the prober reaches is one `.ok` row that names
    /// the server.
    @Test func aServerThatAnswersPasses() async {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-mcpOk")

        let checks = await Self.doctor(
            configuration: Self.configurationWithOneServer(), workingDirectory: workspace
        ).runHealthChecks()

        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(checks.contains { $0.name.contains(Self.serverName) })
    }

    /// A server whose command the prober reports absent is one `.error`
    /// that names the server and the command.
    @Test func anAbsentServerCommandGivesOneErrorThatNamesTheServerAndTheCommand() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-mcpMissing")
        let prober = StubToolsProber(
            namedServers: [Self.serverName: .failed(reason: Self.absentReason)])

        let checks = await Self.doctor(
            configuration: Self.configurationWithOneServer(), workingDirectory: workspace,
            prober: prober
        ).runHealthChecks()

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        let fix = try #require(failure.fix)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(Self.serverName))
        #expect(failure.message.contains(Self.missingCommand))
        #expect(failure.message.contains(Self.absentReason))
        #expect(fix.contains(Self.serverName))
    }

    /// A prober that does not answer in time gives one `.warning`, and the
    /// run ends at the named timeout instead of hanging.
    ///
    /// The proof is by order: the silent probe answers only after the test
    /// opens its gate, and the test opens the gate after the run returned.
    /// A run that waited for the probe would never return, and the time
    /// limit would fail the test.
    @Test(.timeLimit(.minutes(1)))
    func aProberThatDoesNotAnswerInTimeWarnsInsideTheNamedTimeout() async throws {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-mcpSilent")
        let prober = StubToolsProber(silentServers: [Self.serverName])

        let checks = await Self.doctor(
            configuration: Self.configurationWithOneServer(), workingDirectory: workspace,
            prober: prober, timeoutSeconds: Self.shortTimeoutSeconds
        ).runHealthChecks()
        await prober.lateAnswers.open()

        let warnings = Self.findings(.warning, in: checks)
        let warning = try #require(warnings.first)
        #expect(warnings.count == Self.oneFinding)
        #expect(warning.message.contains(Self.serverName))
        #expect(warning.fix != nil)
    }

    /// `tools.mcp: false` gives one `.ok` row that says disabled, and no
    /// server is probed: a prober that fails every server changes nothing.
    @Test func aDisabledMCPSectionSaysDisabledAndProbesNoServer() async {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-mcpOff")
        var configuration = Self.configurationWithOneServer()
        configuration.tools.mcp = .disabled
        let prober = StubToolsProber(server: .failed(reason: Self.absentReason))

        let checks = await Self.doctor(
            configuration: configuration, workingDirectory: workspace, prober: prober
        ).runHealthChecks()

        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(checks.contains { $0.message.contains(Self.disabledWord) })
    }

    // MARK: - The timeout and the fix rule

    /// The component takes ``ToolsDoctor/probeTimeoutSeconds`` when the
    /// caller states no timeout, so the production run carries the named
    /// bound.
    @Test func theDefaultTimeoutIsTheNamedProbeTimeout() {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-timeout")

        let component = ToolsDoctor(
            configuration: AgentConfiguration(), workingDirectory: workspace,
            prober: StubToolsProber())

        #expect(component.timeoutSeconds == ToolsDoctor.probeTimeoutSeconds)
    }

    /// Every finding this component reports that is not `ok` carries a fix,
    /// over a roster that makes the sandbox, one extra write path and one
    /// server all report a fault at once.
    @Test func noWarningOrErrorCarriesANilFix() async {
        let workspace = makeResolvedDirectory(label: "ToolsDoctorTests-fixes")
        var configuration = Self.configurationWithOneServer()
        configuration.sandbox.extraWritePaths = [
            workspace.appendingPathComponent("absent", isDirectory: true).path
        ]
        let prober = StubToolsProber(
            sandbox: .failed(reason: Self.sandboxRefusedReason),
            namedServers: [Self.serverName: .failed(reason: Self.absentReason)])

        let checks = await Self.doctor(
            configuration: configuration, workingDirectory: workspace, prober: prober
        ).runHealthChecks()

        #expect(checks.contains { $0.status != .ok })
        #expect(checks.allSatisfy { $0.status == .ok || $0.fix != nil })
    }
}

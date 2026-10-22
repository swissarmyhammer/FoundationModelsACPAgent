import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The doctor component registry of `acp-agent` (cli-plan.md §5.12): the
/// components registered so far, and the fix rule that holds over every
/// finding they report.
///
/// The registry takes an injected prober, an injected resolver and the two
/// machine figures, so the tools component starts no confined command and
/// no MCP server here, the profile component asks no network endpoint, and
/// no finding depends on the machine the suite runs on.
struct DoctorRegistryTests {
    // MARK: - Constants

    /// A top-level section no schema section is named after, which makes
    /// the configuration component warn.
    private static let unknownSectionName = "surprise"

    /// The number of components the registry states.
    private static let registeredComponentCount = 6

    /// A memory figure far above the profile floor, so the profile
    /// component does not report the machine this suite runs on.
    private static let generousMemoryBytes: Int64 = 68_719_476_736

    /// A free-disk figure far above any download, for the same reason.
    private static let generousDiskBytes: Int64 = 1_099_511_627_776

    // MARK: - Helpers

    /// The registered components over `fixture`'s stack.
    ///
    /// - Parameter fixture: The two-layer tree the components read.
    /// - Returns: The components, in registration order.
    private static func components(in fixture: ConfigCommandFixture) -> [any Doctorable] {
        AcpAgentCommand.Doctor.components(
            workingDirectory: fixture.workspace, environment: fixture.environment,
            prober: StubToolsProber(), resolver: StubModelResolver(),
            memoryBytes: generousMemoryBytes, freeDiskBytes: generousDiskBytes)
    }

    // MARK: - The registry

    /// The registry states the configuration component, the home component,
    /// the profile component, the transcripts component, the tools component
    /// and the runtime component, in that order.
    @Test func theRegistryStatesTheComponentsInPlanOrder() {
        let fixture = ConfigCommandFixture(label: "DoctorRegistryTests-registry")

        let components = Self.components(in: fixture)

        #expect(components.count == Self.registeredComponentCount)
        #expect(
            components.map(\.doctorCategory) == [
                ConfigurationDoctor.category, HomeDoctor.category, ProfileDoctor.category,
                TranscriptsDoctor.category, ToolsDoctor.category,
                RuntimeDoctor.category,
            ])
    }

    /// `doctor` shows the resolved home: with `ACP_AGENT_HOME`, the home rows
    /// name the synced and the local folder of that home.
    @Test func theHomeRowsNameTheResolvedHome() async throws {
        let fixture = ConfigCommandFixture(label: "DoctorRegistryTests-home")
        let homeFolder = makeResolvedDirectory(label: "DoctorRegistryTests-homeFolder")
        let environment = fixture.environment.merging(
            [AgentComposition.homeVariable: homeFolder.path]) { _, new in new }
        let home = try AgentComposition.home(environment: environment)

        let components = AcpAgentCommand.Doctor.components(
            workingDirectory: fixture.workspace, environment: environment,
            prober: StubToolsProber(), resolver: StubModelResolver(),
            memoryBytes: Self.generousMemoryBytes, freeDiskBytes: Self.generousDiskBytes)
        let homeDoctor = try #require(components.lazy.compactMap { $0 as? HomeDoctor }.first)
        let checks = await homeDoctor.runHealthChecks()

        #expect(checks.contains { $0.message.contains(home.synced.standardizedFileURL.path) })
        #expect(checks.contains { $0.message.contains(home.local.standardizedFileURL.path) })
    }

    // MARK: - The fix rule

    /// Every finding these components report that is not `ok` carries a
    /// fix: a person who reads a warning or a failure is told what to do
    /// about it.
    @Test func noWarningOrErrorCarriesANilFix() async throws {
        let fixture = ConfigCommandFixture(label: "DoctorRegistryTests-fixes")
        try fixture.writeProjectConfig("\(Self.unknownSectionName):\n  key: yes\n")

        let report = await DoctorRunner(components: Self.components(in: fixture)).run()

        #expect(report.checks.contains { $0.status == .warning })
        #expect(report.checks.allSatisfy { $0.status == .ok || $0.fix != nil })
    }
}

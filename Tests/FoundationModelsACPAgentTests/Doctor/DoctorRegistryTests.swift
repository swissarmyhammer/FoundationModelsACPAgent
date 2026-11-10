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
/// The registry takes an injected resolver and the two machine figures, so
/// the profile component asks no network endpoint here, and no finding
/// depends on the machine the suite runs on.
struct DoctorRegistryTests {
  // MARK: - Constants

  /// A top-level section no schema section is named after, which makes
  /// the configuration component warn.
  private static let unknownSectionName = "surprise"

  /// The group the removed tools component reported in. No component of
  /// the registry may report in it.
  private static let toolsCategory = "tools"

  /// The number of components the registry states.
  private static let registeredComponentCount = 5

  // MARK: - Helpers

  /// The registered components over `fixture`'s stack.
  ///
  /// - Parameters:
  ///   - fixture: The two-layer tree the components read.
  ///   - environment: The environment the components read, or `nil` (the
  ///     default) for the environment of `fixture`.
  /// - Returns: The components, in registration order.
  private static func components(
    in fixture: ConfigCommandFixture, environment: [String: String]? = nil
  ) -> [any Doctorable] {
    AcpAgentCommand.Doctor.components(
      workingDirectory: fixture.workspace, environment: environment ?? fixture.environment,
      resolver: StubModelResolver(),
      memoryBytes: DoctorMachineFigures.generousMemoryBytes,
      freeDiskBytes: DoctorMachineFigures.generousDiskBytes)
  }

  // MARK: - The registry

  /// The registry states the configuration component, the home component,
  /// the profile component, the transcripts component and the runtime
  /// component, in that order.
  @Test func theRegistryStatesTheComponentsInPlanOrder() {
    let fixture = ConfigCommandFixture(label: "DoctorRegistryTests-registry")

    let components = Self.components(in: fixture)

    #expect(components.count == Self.registeredComponentCount)
    #expect(
      components.map(\.doctorCategory) == [
        ConfigurationDoctor.category, HomeDoctor.category, ProfileDoctor.category,
        TranscriptsDoctor.category, RuntimeDoctor.category,
      ])
  }

  /// The registry states no tools component: the shell has no sandbox to
  /// probe (ACPA-19), so no component reports in the tools group.
  @Test func theRegistryHasNoToolsComponent() {
    let fixture = ConfigCommandFixture(label: "DoctorRegistryTests-no-tools")

    let components = Self.components(in: fixture)

    #expect(!components.contains { $0.doctorCategory == Self.toolsCategory })
  }

  /// `doctor` shows the resolved home: with `ACP_AGENT_HOME`, the home rows
  /// name the synced and the local folder of that home.
  @Test func theHomeRowsNameTheResolvedHome() async throws {
    let fixture = ConfigCommandFixture(label: "DoctorRegistryTests-home")
    let homeFolder = makeResolvedDirectory(label: "DoctorRegistryTests-homeFolder")
    let environment = fixture.environment.merging(
      [AgentComposition.homeVariable: homeFolder.path]) { _, new in new }
    let home = try AgentComposition.home(environment: environment)

    let components = Self.components(in: fixture, environment: environment)
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

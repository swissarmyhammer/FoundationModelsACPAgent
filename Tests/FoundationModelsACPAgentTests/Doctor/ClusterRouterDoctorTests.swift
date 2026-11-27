import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsCluster
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The `doctor` component of the cluster (task ^j1vfmkf): when the `cluster:` section of the user
/// level is enabled, `acp-agent doctor` shows the cluster report of the Router
/// (`router.clusterReport()`), so a run can be checked before a bench.
///
/// The component takes the report from a closure, so no test runs SSH or asks the network.
@Suite struct ClusterRouterDoctorTests {
  // MARK: - Constants

  /// The host name of this Mac in a report.
  private static let head = "m5u1"

  /// The host name of the other Mac in a report.
  private static let member = "m5u2"

  /// The fix line of the failure of a report.
  private static let fix = "m5u2 is cabled but RDMA is off (setup.md step 1)"

  // MARK: - Helpers

  /// An enabled section.
  private static var enabled: ClusterConfiguration {
    var section = ClusterConfiguration()
    section.enabled = true
    return section
  }

  /// A report of two Macs with one finding.
  ///
  /// - Parameters:
  ///   - status: The status of the report.
  ///   - findings: The findings of the report.
  /// - Returns: The report.
  private static func report(
    status: ClusterReport.Status, findings: [ClusterFinding] = []
  ) -> ClusterReport {
    ClusterReport(
      status: status, head: MacReport(name: head, sshHost: nil, role: .head, probed: true),
      members: [MacReport(name: member, sshHost: member, role: .member, probed: true)],
      cluster: [head, member], graph: CableGraph(macs: [head, member], cables: []),
      findings: findings, login: .ssh)
  }

  /// The checks of a component over an enabled section and `report`.
  ///
  /// - Parameter report: The report the Router gives.
  /// - Returns: The checks.
  private static func checks(of report: ClusterReport) async -> [HealthCheck] {
    await ClusterRouterDoctor(section: .loaded(enabled)) { _ in report }.runHealthChecks()
  }

  // MARK: - When it applies

  /// The component does not apply when the cluster is off.
  @Test func theComponentDoesNotApplyWhenTheClusterIsOff() {
    let doctor = ClusterRouterDoctor(section: .loaded(ClusterConfiguration())) { _ in
      Self.report(status: .full)
    }

    #expect(!doctor.isApplicable)
  }

  /// The component applies when the cluster is enabled.
  @Test func theComponentAppliesWhenTheClusterIsEnabled() {
    let doctor = ClusterRouterDoctor(section: .loaded(Self.enabled)) { _ in
      Self.report(status: .full)
    }

    #expect(doctor.isApplicable)
  }

  // MARK: - The report

  /// The first check shows the status and the Macs of the report.
  @Test func theFirstCheckShowsTheStatusAndTheMacs() async throws {
    let first = try #require(await Self.checks(of: Self.report(status: .full)).first)

    #expect(first.status == .ok && first.message.contains("full") && first.message.contains(Self.member))
  }

  /// A report with no cluster is a warning: the cluster is enabled, and no model can use it.
  @Test func aReportWithNoClusterIsAWarning() async throws {
    let first = try #require(await Self.checks(of: Self.report(status: .none)).first)

    #expect(first.status == .warning)
  }

  /// A failure of the report is an error check with its fix line.
  @Test func aFailureOfTheReportIsAnErrorWithItsFix() async {
    let finding = ClusterFinding(
      mac: Self.member, check: .rdma, severity: .failure, fix: Self.fix, step: .rdma)

    let checks = await Self.checks(of: Self.report(status: .partial, findings: [finding]))

    #expect(checks.contains { $0.status == .error && $0.fix == Self.fix })
  }

  /// A section of the user level that does not load is an error check, and the component
  /// applies.
  @Test func aSectionThatDoesNotLoadIsAnError() async {
    let doctor = ClusterRouterDoctor(section: .failed("no value")) { _ in
      Self.report(status: .full)
    }

    #expect(doctor.isApplicable)
    #expect(await doctor.runHealthChecks().map(\.status) == [.error])
  }

  // MARK: - The registry

  /// `doctor` registers the component over the section of the user level.
  @Test func theRegistryHasTheComponentOfTheUserLevel() throws {
    let fixture = ConfigCommandFixture(label: "ClusterRouterDoctorTests-registry")
    try fixture.writeUserConfig("cluster:\n  enabled: true\n")

    let components = AcpAgentCommand.Doctor.components(
      workingDirectory: fixture.workspace, environment: fixture.environment,
      resolver: StubModelResolver(),
      memoryBytes: DoctorMachineFigures.generousMemoryBytes,
      freeDiskBytes: DoctorMachineFigures.generousDiskBytes)

    let doctor = try #require(components.lazy.compactMap { $0 as? ClusterRouterDoctor }.first)
    #expect(doctor.isApplicable)
  }
}

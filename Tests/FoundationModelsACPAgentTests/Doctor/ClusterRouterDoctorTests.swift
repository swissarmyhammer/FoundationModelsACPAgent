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

  /// The label of the throwaway folders of the suite.
  private static let label = "ClusterRouterDoctorTests"

  /// The `config.yaml` text of an enabled password login, whose password is a Keychain
  /// reference.
  private static let passwordLoginYAML = """
    cluster:
      enabled: true
      user: ml
      password: keychain:\(passwordReference)
    """

  /// The Keychain reference of the password of ``passwordLoginYAML``.
  private static let passwordReference = "cluster-password"

  /// The error of a password whose reference has no value.
  private static let unresolvedPassword = ConfigurationError.unresolvedSecret(
    keyPath: "cluster.password", reference: passwordReference)

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
    await ClusterRouterDoctor(section: { enabled }) { _ in report }.runHealthChecks()
  }

  // MARK: - When it reports

  /// The component reports nothing when the cluster is off.
  @Test func theComponentReportsNothingWhenTheClusterIsOff() async {
    let doctor = ClusterRouterDoctor(section: { ClusterConfiguration() }) { _ in
      Self.report(status: .full)
    }

    #expect(await doctor.runHealthChecks().isEmpty)
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

  /// A section of the user level that does not load is an error check.
  @Test func aSectionThatDoesNotLoadIsAnError() async {
    let doctor = ClusterRouterDoctor(section: { throw Self.unresolvedPassword }) { _ in
      Self.report(status: .full)
    }

    #expect(await doctor.runHealthChecks().map(\.status) == [.error])
  }

  // MARK: - The read of the section

  /// Making the component reads no configuration and no Keychain item: the read waits for the
  /// checks, because a Keychain read can prompt the person.
  @Test func makingTheComponentReadsNoSecret() throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(Self.passwordLoginYAML, in: fixture.userDirectory)
    let store = CountingSecretStore()

    _ = ClusterRouterDoctor(
      loader: try fixture.makeLoader(secretStore: store), home: AgentHomeFixture.make(label: Self.label))

    #expect(store.reads.count == 0)
  }

  /// The checks read the section of the loader: a password with no value in the Keychain is an
  /// error check.
  @Test func theChecksReadTheSectionOfTheLoader() async throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(Self.passwordLoginYAML, in: fixture.userDirectory)
    let doctor = ClusterRouterDoctor(
      loader: try fixture.makeLoader(), home: AgentHomeFixture.make(label: Self.label))

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
    #expect(try doctor.loadSection().enabled)
  }
}

/// A secret store that counts its reads and gives one value for each reference. It is an
/// in-memory test double: no test that uses it touches the real Keychain.
private struct CountingSecretStore: SecretStore {
  /// The value of each reference.
  private static let value = "cluster-secret"

  /// The reads so far.
  let reads = CallCounter()

  /// Records the read and gives the value.
  ///
  /// - Parameter name: The reference name.
  /// - Returns: The value of the store.
  func value(forReference name: String) throws -> String? {
    reads.record()
    return Self.value
  }
}

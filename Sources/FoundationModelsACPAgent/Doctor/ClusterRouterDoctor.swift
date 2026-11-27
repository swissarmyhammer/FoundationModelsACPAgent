import Foundation
import FoundationModelsCluster
import FoundationModelsExtras
import HuggingFace

/// The `doctor` component of the Mac cluster (task ^j1vfmkf): when the `cluster:` section of the
/// user level is enabled, it shows the cluster report of a live Router built with that section
/// (`Router.clusterReport()`), so a person can check the cluster before a run.
///
/// The first check gives the status of the report, the Macs that a load would use and the
/// login. Each finding of the report is one more check: an info finding passes, a warning warns,
/// and a failure is an error with its fix line. The report holds no secret.
///
/// The component applies only when the section is enabled, or when the section does not load: a
/// login secret with no value in the Keychain does not stop the load of `config.yaml`, thus this
/// component reports it.
public struct ClusterRouterDoctor: Doctorable {
  // MARK: - Constants

  /// The group every finding of this component belongs to.
  public static let category = "cluster"

  /// The name of the first check, which gives the status of the report.
  private static let statusCheckName = "cluster"

  /// The fix of a report with no cluster.
  private static let noClusterFix =
    "fix the cluster findings below, then run acp-agent doctor again"

  /// The fix of a section that does not load.
  private static let sectionFix =
    "correct the cluster section of the user config.yaml, and give each secret as a "
    + "keychain:<name> reference that has a value in the Keychain"

  /// The separator of the names of the Macs in a message.
  private static let macSeparator = ", "

  // MARK: - Types

  /// The `cluster:` section of the user level, as the component read it.
  enum Section: Sendable {
    /// The section, with each login secret resolved.
    case loaded(ClusterConfiguration)

    /// The read of the section failed; the text of the error, which holds no secret value.
    case failed(String)
  }

  /// Gives the cluster report of a Router built with a section.
  typealias ReportSource = @Sendable (ClusterConfiguration) async throws -> ClusterReport

  // MARK: - Stored state

  /// The section of the user level.
  private let section: Section

  /// The source of the report.
  private let report: ReportSource

  // MARK: - Doctorable

  /// What this component is called in the doctor report.
  public let doctorName = ClusterRouterDoctor.category

  /// The group its findings belong to.
  public let doctorCategory = ClusterRouterDoctor.category

  /// Whether the checks apply: the section is enabled, or it does not load.
  public var isApplicable: Bool {
    switch section {
    case .loaded(let cluster): cluster.enabled
    case .failed: true
    }
  }

  // MARK: - Making

  /// Makes the component over the section of the user level that `loader` reads
  /// (``ConfigurationLoader/loadUserCluster()``), and a live Router of `home` for the report.
  ///
  /// The init reads the configuration files and the Keychain, and builds no Router: the Router
  /// is built only when the checks run, and only for an enabled section.
  ///
  /// - Parameters:
  ///   - loader: The configuration loader of the `doctor` command.
  ///   - home: The home of the host, whose caches the Router uses.
  ///   - huggingFaceTokenProvider: The provider of the Hugging Face token of the Router. The
  ///     default `.environment` reads `HF_TOKEN`, then `~/.cache/huggingface/token`.
  public init(
    loader: ConfigurationLoader, home: AgentHome, huggingFaceTokenProvider: TokenProvider = .environment
  ) {
    let section: Section
    do {
      section = .loaded(try loader.loadUserCluster())
    } catch {
      section = .failed(String(describing: error))
    }
    self.init(section: section) { cluster in
      try await ComposedAgent.makeLiveRouter(
        home: home, huggingFaceTokenProvider: huggingFaceTokenProvider, cluster: cluster
      ).clusterReport()
    }
  }

  /// Makes the component over a section and a source of the report.
  ///
  /// - Parameters:
  ///   - section: The section of the user level.
  ///   - report: Gives the cluster report of a Router built with the section.
  init(section: Section, report: @escaping ReportSource) {
    self.section = section
    self.report = report
  }

  // MARK: - Checks

  /// Reports the status of the cluster report, then one check for each finding.
  ///
  /// - Returns: The checks; one error when the section does not load or the Router cannot be
  ///   built.
  public func runHealthChecks() async -> [HealthCheck] {
    switch section {
    case .failed(let reason):
      return [Self.sectionError(reason)]
    case .loaded(let cluster):
      do {
        return Self.checks(of: try await report(cluster))
      } catch {
        return [Self.sectionError(String(describing: error))]
      }
    }
  }

  /// The error check of a section that does not load.
  ///
  /// - Parameter reason: The text of the error.
  /// - Returns: The check.
  private static func sectionError(_ reason: String) -> HealthCheck {
    .error(
      name: statusCheckName, message: "the cluster section does not load: \(reason)",
      fix: sectionFix, category: category)
  }

  /// The checks of a report: its status, then each finding.
  ///
  /// - Parameter report: The cluster report.
  /// - Returns: The checks.
  static func checks(of report: ClusterReport) -> [HealthCheck] {
    [statusCheck(of: report)] + report.findings.map(check(of:))
  }

  /// The check of the status of a report. A report with no cluster warns, unless it says why
  /// the models run on this Mac.
  ///
  /// - Parameter report: The cluster report.
  /// - Returns: The check.
  private static func statusCheck(of report: ClusterReport) -> HealthCheck {
    if let reason = report.localReason {
      return .ok(
        name: statusCheckName, message: "models run on this Mac: \(reason)", category: category)
    }
    let message =
      "cluster status: \(report.status.rawValue); Macs: "
      + report.cluster.joined(separator: macSeparator) + "; login: \(report.login.rawValue)"
    guard report.status == .none else {
      return .ok(name: statusCheckName, message: message, category: category)
    }
    return .warning(name: statusCheckName, message: message, fix: noClusterFix, category: category)
  }

  /// The check of one finding of a report. A finding about one Mac names that Mac.
  ///
  /// - Parameter finding: The finding.
  /// - Returns: The check.
  private static func check(of finding: ClusterFinding) -> HealthCheck {
    let name = finding.mac ?? statusCheckName
    let message = "\(finding.check.rawValue): \(finding.fix)"
    switch finding.severity {
    case .info:
      return .ok(name: name, message: message, category: category)
    case .warning:
      return .warning(name: name, message: message, fix: finding.fix, category: category)
    case .failure:
      return .error(name: name, message: message, fix: finding.fix, category: category)
    }
  }
}

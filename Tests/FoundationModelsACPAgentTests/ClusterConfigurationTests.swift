import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsCluster
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The `cluster:` section of `config.yaml` (task ^j1vfmkf): the mode and the
/// options of the Mac cluster that the agent gives to the Router. An absent
/// section keeps the cluster off.
@Suite struct ClusterConfigurationTests {
  // MARK: - Constants

  /// A host name of the `hosts` key.
  private static let host = "m5u2.local"

  /// The `sshKey` value, under the home folder.
  private static let sshKeyValue = "~/.ssh/id_ed25519"

  /// The path of ``sshKeyValue`` under the home folder.
  private static let sshKeyRelativePath = ".ssh/id_ed25519"

  /// The `workerDirectory` value, under the home folder.
  private static let workerDirectoryValue = "~/fmcluster"

  /// The path of ``workerDirectoryValue`` under the home folder.
  private static let workerDirectoryRelativePath = "fmcluster"

  // MARK: - Helpers

  /// The `cluster` section of a `config.yaml` text.
  ///
  /// - Parameter yaml: The text of the file.
  /// - Returns: The decoded section.
  /// - Throws: The parse or the decode error.
  private static func section(of yaml: String) throws -> ClusterConfiguration {
    try YAMLValue.parse(yaml).decoded(as: AgentConfiguration.self).cluster
  }

  /// The `cluster` section with `enabled: true` and one more line.
  ///
  /// - Parameter line: The key line under the section, or none.
  /// - Returns: The decoded section.
  /// - Throws: The parse or the decode error.
  private static func enabledSection(with line: String = "") throws -> ClusterConfiguration {
    try section(of: "cluster:\n  enabled: true\n" + (line.isEmpty ? "" : "  \(line)\n"))
  }

  /// The path of a file under the home folder of the user.
  ///
  /// - Parameter relativePath: The path under the home folder.
  /// - Returns: The absolute path.
  private static func homePath(_ relativePath: String) -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(relativePath).standardizedFileURL.path
  }

  /// The path of the key file of an SSH mode.
  ///
  /// - Parameter mode: The mode.
  /// - Returns: The path, or `nil` when the mode has no key file.
  private static func keyPath(of mode: ClusterMode) -> String? {
    guard case .ssh(.file(let file, _)?, _) = mode else {
      return nil
    }
    return file.standardizedFileURL.path
  }

  /// The folder of a worker source of a folder.
  ///
  /// - Parameter source: The worker source.
  /// - Returns: The path, or `nil` for a bundled source.
  private static func directoryPath(of source: WorkerSource) -> String? {
    guard case .directory(let directory) = source else {
      return nil
    }
    return directory.standardizedFileURL.path
  }

  // MARK: - The section

  /// The builtin file gives the default section.
  @Test func theBuiltinFileGivesTheDefaultSection() throws {
    let decoded = try BuiltinConfigurationFile.root().decoded(as: AgentConfiguration.self)

    #expect(decoded.cluster == ClusterConfiguration())
  }

  /// A configuration with no `cluster` section keeps the cluster off.
  @Test func anAbsentSectionTurnsTheClusterOff() throws {
    #expect(try Self.section(of: "theme: dark\n").mode == .off)
  }

  /// `enabled: true` with no key logs in with the SSH agent and `~/.ssh`.
  @Test func enabledWithNoKeyLogsInWithTheSSHAgent() throws {
    #expect(try Self.enabledSection().mode == .ssh())
  }

  /// `enabled: false` keeps the cluster off, also with a key.
  @Test func enabledFalseKeepsTheClusterOff() throws {
    let section = try Self.section(
      of: "cluster:\n  enabled: false\n  sshKey: \(Self.sshKeyValue)\n")

    #expect(section.mode == .off)
  }

  /// `sshKey` is a key file, with `~` expanded to the home folder.
  @Test func theSSHKeyIsAKeyFileUnderTheHomeFolder() throws {
    let section = try Self.enabledSection(with: "sshKey: \(Self.sshKeyValue)")

    #expect(Self.keyPath(of: section.mode) == Self.homePath(Self.sshKeyRelativePath))
  }

  /// `hosts` gives the hosts of the options.
  @Test func theHostsAreTheHostsOfTheOptions() throws {
    let section = try Self.enabledSection(with: "hosts: [\(Self.host)]")

    #expect(section.options.hosts == [Self.host])
  }

  /// No `hosts` browses with Bonjour: the options have no hosts.
  @Test func noHostsBrowsesWithBonjour() throws {
    #expect(try Self.enabledSection().options.hosts == nil)
  }

  /// No `policy` clusters when the cluster is measured faster.
  @Test func theDefaultPolicyIsWhenFaster() throws {
    #expect(try Self.enabledSection().options.policy == .whenFaster)
  }

  /// Each `policy` word gives the policy of the same name.
  @Test(arguments: [
    ("whenFaster", ClusterOptions.Policy.whenFaster),
    ("whenNeeded", ClusterOptions.Policy.whenNeeded),
    ("always", ClusterOptions.Policy.always),
  ])
  func eachPolicyWordGivesItsPolicy(word: String, policy: ClusterOptions.Policy) throws {
    #expect(try Self.enabledSection(with: "policy: \(word)").options.policy == policy)
  }

  /// A `policy` word in another case decodes, as `theme` and `keymap` do.
  @Test func aPolicyWordInAnotherCaseDecodes() throws {
    #expect(try Self.enabledSection(with: "policy: WhenNeeded").options.policy == .whenNeeded)
  }

  /// A `policy` that is not a policy fails with an error that names the
  /// choices.
  @Test func aBadPolicyFailsWithTheChoices() throws {
    let error = #expect(throws: (any Error).self) {
      try Self.enabledSection(with: "policy: sometimes")
    }

    #expect(String(describing: error).contains("whenFaster, whenNeeded, always"))
  }

  /// `workerDirectory` is the worker source, with `~` expanded.
  @Test func theWorkerDirectoryIsTheWorkerSource() throws {
    let section = try Self.enabledSection(with: "workerDirectory: \(Self.workerDirectoryValue)")

    #expect(
      Self.directoryPath(of: section.options.workerSource)
        == Self.homePath(Self.workerDirectoryRelativePath))
  }

  /// No `workerDirectory` uses the worker bundled in the app.
  @Test func noWorkerDirectoryUsesTheBundledWorker() throws {
    #expect(try Self.enabledSection().options.workerSource == .bundled())
  }

  /// A key that the section does not have is an error of the load.
  @Test func anUnknownKeyIsAnErrorOfTheLoad() throws {
    let fixture = ConfigurationLoaderTests.Fixture()

    #expect(
      throws: ConfigurationError.unknownKey(
        section: ClusterConfiguration.sectionKey, key: "password")
    ) {
      try fixture.loadProjectConfig("cluster:\n  password: secret\n")
    }
  }
}

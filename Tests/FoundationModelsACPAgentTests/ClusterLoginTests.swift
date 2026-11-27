import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsCluster
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The login keys of the `cluster:` section (task ^j1vfmkf): `user`, and the secrets `password`,
/// `adminPassword` and `sshKeyPassphrase`. Each secret takes only a `keychain:<name>` reference;
/// the read of the user level resolves it through the secret store of the loader.
@Suite struct ClusterLoginTests {
  // MARK: - Constants

  /// The SSH user of a password login.
  private static let user = "ml"

  /// The name of the Keychain reference of each secret.
  private static let referenceName = "cluster-secret"

  /// The value of the reference in the secret store.
  private static let secretValue = "s3cret-value"

  /// The `keychain:<name>` text of the reference.
  private static let reference = ConfiguredSecret.referencePrefix + referenceName

  /// The `sshKey` value of a key login.
  private static let sshKey = "/tmp/id_cluster"

  // MARK: - Helpers

  /// The `config.yaml` text of an enabled section with `lines` under it.
  ///
  /// - Parameter lines: The key lines of the section.
  /// - Returns: The text.
  private static func yaml(_ lines: [String]) -> String {
    "cluster:\n  enabled: true\n" + lines.map { "  \($0)\n" }.joined()
  }

  /// The section of the user level that the loader reads, with the reference of
  /// ``referenceName`` in the secret store.
  ///
  /// - Parameters:
  ///   - lines: The key lines of the section.
  ///   - values: The values of the secret store.
  /// - Returns: The section.
  /// - Throws: What the read throws.
  private static func userSection(
    _ lines: [String], values: [String: String] = [referenceName: secretValue]
  ) throws -> ClusterConfiguration {
    let fixture = ConfigurationLoaderTests.Fixture()
    fixture.writeConfig(yaml(lines), in: fixture.userDirectory)
    return try fixture.makeLoader(secretStore: InMemorySecretStore(values)).loadUserCluster()
  }

  /// The text of the error that the decode of a section throws.
  ///
  /// - Parameter lines: The key lines of the section.
  /// - Returns: The text of the error, or none when the decode does not throw.
  private static func decodeError(_ lines: [String]) -> String {
    do {
      _ = try YAMLValue.parse(yaml(lines)).decoded(as: AgentConfiguration.self)
      return ""
    } catch {
      return String(describing: error)
    }
  }

  // MARK: - The logins

  /// `user` and `password` give a password login with the value of the reference.
  @Test func userAndPasswordGiveAPasswordLogin() throws {
    let section = try Self.userSection(["user: \(Self.user)", "password: \(Self.reference)"])

    #expect(
      try section.mode == .password(user: Self.user, password: ClusterSecret(Self.secretValue)))
  }

  /// `adminPassword` gives an SSH login with the admin password of the reference.
  @Test func adminPasswordGivesTheAdminPasswordOfTheSSHLogin() throws {
    let section = try Self.userSection(["adminPassword: \(Self.reference)"])

    #expect(try section.mode == .ssh(key: nil, adminPassword: ClusterSecret(Self.secretValue)))
  }

  /// `sshKeyPassphrase` gives the passphrase of the key file.
  @Test func sshKeyPassphraseGivesThePassphraseOfTheKeyFile() throws {
    let section = try Self.userSection([
      "sshKey: \(Self.sshKey)", "sshKeyPassphrase: \(Self.reference)",
    ])

    #expect(
      try section.mode
        == .ssh(
          key: .file(
            URL(fileURLWithPath: Self.sshKey), passphrase: ClusterSecret(Self.secretValue))))
  }

  /// A reference with no value in the secret store is an error of the read.
  @Test func aReferenceWithNoValueIsAnError() throws {
    #expect(
      throws: ConfigurationError.unresolvedSecret(
        keyPath: "cluster.password", reference: Self.referenceName)
    ) {
      try Self.userSection(["user: \(Self.user)", "password: \(Self.reference)"], values: [:])
    }
  }

  // MARK: - The rules

  /// A literal secret is an error that says to use a `keychain:<name>` reference.
  @Test(arguments: ["password", "adminPassword", "sshKeyPassphrase"])
  func aLiteralSecretIsAnError(key: String) {
    let lines = ["user: \(Self.user)", "sshKey: \(Self.sshKey)", "\(key): plain-text"]

    #expect(Self.decodeError(lines).contains("cluster.\(key) takes only a keychain:<name> reference"))
  }

  /// `password` with no `user` is an error.
  @Test func aPasswordNeedsAUser() {
    #expect(Self.decodeError(["password: \(Self.reference)"]).contains("cluster.password needs cluster.user"))
  }

  /// `user` with no `password` is an error.
  @Test func aUserNeedsAPassword() {
    #expect(Self.decodeError(["user: \(Self.user)"]).contains("cluster.user needs cluster.password"))
  }

  /// `password` with a key of the SSH login is an error.
  @Test(arguments: [
    "sshKey: \(sshKey)", "adminPassword: \(reference)", "sshKeyPassphrase: \(reference)",
  ])
  func aPasswordWithAKeyOfTheSSHLoginIsAnError(line: String) {
    let lines = ["user: \(Self.user)", "password: \(Self.reference)", line]

    #expect(Self.decodeError(lines).contains("cluster.password cannot be used with"))
  }

  /// `sshKeyPassphrase` with no `sshKey` is an error.
  @Test func aPassphraseNeedsAKeyFile() {
    #expect(
      Self.decodeError(["sshKeyPassphrase: \(Self.reference)"])
        .contains("cluster.sshKeyPassphrase needs cluster.sshKey"))
  }

  // MARK: - What a document shows

  /// The document of a configuration shows the reference of a secret and never its value.
  @Test func theDocumentShowsTheReferenceAndNotTheValue() throws {
    var configuration = AgentConfiguration()
    configuration.cluster = try Self.userSection([
      "user: \(Self.user)", "password: \(Self.reference)",
    ])

    let text = try ConfigurationYAML.documentText(for: configuration)

    #expect(text.contains(Self.reference) && !text.contains(Self.secretValue))
  }

  // MARK: - Fast synch

  /// Each enabled login keeps fast synch on: the cluster is of no use without it, and the
  /// section has no key for it.
  @Test(arguments: [
    [String](), ["sshKey: \(sshKey)"], ["user: \(user)", "password: \(reference)"],
  ])
  func eachEnabledLoginKeepsFastSynchOn(lines: [String]) throws {
    #expect(try Self.userSection(lines).options.fastSynch)
  }
}

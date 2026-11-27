import Foundation
import FoundationModelsCluster

// MARK: - cluster

/// The `cluster:` section: whether the Router may run a model across Macs cabled with
/// Thunderbolt, and how (task ^j1vfmkf).
///
/// There is one Router for each process, thus the agent reads the section at the user level
/// only, before it builds the Router (``ConfigurationLoader/loadUserCluster()``). A session level
/// of a folder may hold the section, and the load checks it as each other section, but the agent
/// ignores it. The live model path gives ``mode`` and ``options`` to the Router and to its loader;
/// the stub path ignores the section.
///
/// The file holds no key text, only the path of a key file, and no password: each login secret
/// (``password``, ``adminPassword``, ``sshKeyPassphrase``) takes only a `keychain:<name>`
/// reference, which ``ConfigurationLoader/loadUserCluster()`` resolves through the secret store of
/// the loader. `ClusterMode` is not `Codable` on purpose. A document shows each reference and
/// never a value. A `~` at the start of a path is the home folder of the user.
///
/// The login rules: ``password`` needs ``user`` and ``user`` needs ``password`` (a password
/// login); a password login takes no ``sshKey``, ``adminPassword`` or ``sshKeyPassphrase`` (the
/// keys of an SSH login); ``sshKeyPassphrase`` needs ``sshKey``. Fast synch is always on: the
/// section has no key for it.
public struct ClusterConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The key of the section in the root of `config.yaml`.
  public static let sectionKey = AgentConfiguration.CodingKeys.cluster.stringValue

  /// The help of the section, for the `settings` tool.
  public static let help =
    "The key paths [\"cluster\", <key>] set the Mac cluster of the Router, at the user level only "
    + "(the agent ignores a session level), and apply at the next launch: enabled (true or false), "
    + "hosts (a list of host names; absent browses with Bonjour), sshKey (the path of a key file; "
    + "absent uses the SSH agent and ~/.ssh), sshKeyPassphrase (the passphrase of sshKey), "
    + "adminPassword (the admin password that turns off Thunderbolt Bridge on a Mac), user and "
    + "password (a password login, with no sshKey, sshKeyPassphrase or adminPassword), policy "
    + "(whenFaster, whenNeeded or always) and workerDirectory (the folder of fmcluster-worker and "
    + "mlx.metallib; absent uses the worker bundled in the app). Each secret takes only a "
    + "keychain:<name> reference."

  /// When true, the Router may run a model across the Macs. When false, each model runs on this
  /// Mac (`ClusterMode.off`).
  public var enabled = false

  /// The host names of the Macs, or `nil` to find them with Bonjour.
  public var hosts: [String]?

  /// The path of the SSH key file that logs in to the Macs, or `nil` for the SSH agent and the
  /// keys in `~/.ssh`.
  public var sshKey: String?

  /// The passphrase of the key file of ``sshKey``, as a `keychain:<name>` reference, or `nil`
  /// for a key file with no passphrase.
  public var sshKeyPassphrase: ConfiguredSecret?

  /// The admin password of the Macs, as a `keychain:<name>` reference, or `nil`. The cluster
  /// uses it to turn off Thunderbolt Bridge on a Mac.
  public var adminPassword: ConfiguredSecret?

  /// The SSH user of a password login, or `nil` for an SSH login with a key.
  public var user: String?

  /// The password of a password login, the same on each Mac, as a `keychain:<name>` reference,
  /// or `nil` for an SSH login with a key.
  public var password: ConfiguredSecret?

  /// When the Router splits a model across the Macs.
  public var policy = Policy.whenFaster

  /// The folder that holds `fmcluster-worker` and `mlx.metallib`, or `nil` for the worker bundled
  /// in the app.
  public var workerDirectory: String?

  /// The YAML spelling of each key.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case enabled, hosts, sshKey, sshKeyPassphrase, adminPassword, user, password, policy
    case workerDirectory
  }

  /// The keys of an SSH login, which a password login does not take.
  private static let sshLoginKeys: [CodingKeys] = [.sshKey, .adminPassword, .sshKeyPassphrase]

  /// The `policy` key: when the Router splits a model across the Macs.
  public enum Policy: String, Codable, CaseIterable, Sendable, CaseInsensitiveChoice {
    /// When the cluster is measured faster than this Mac.
    case whenFaster

    /// Only when the model does not fit on this Mac.
    case whenNeeded

    /// Each time the cluster can run the model.
    case always

    /// The cluster policy of the same name.
    var clusterPolicy: ClusterOptions.Policy {
      switch self {
      case .whenFaster: .whenFaster
      case .whenNeeded: .whenNeeded
      case .always: .always
      }
    }

    /// The YAML spelling of the key, for the error text.
    static var keyName: String { CodingKeys.policy.stringValue }
  }

  /// The default: the cluster is off.
  public init() {}

  /// Decodes each present key, keeps the default for each absent one, and checks the login
  /// rules.
  ///
  /// - Parameter decoder: The decoder of the section.
  /// - Throws: `DecodingError` when a key has the wrong type, `policy` is not a policy, a secret
  ///   is not a `keychain:<name>` reference, or the keys break a login rule.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    hosts = try container.decodeIfPresent([String].self, forKey: .hosts)
    sshKey = try container.decodeIfPresent(String.self, forKey: .sshKey)
    sshKeyPassphrase = try Self.reference(in: container, forKey: .sshKeyPassphrase)
    adminPassword = try Self.reference(in: container, forKey: .adminPassword)
    user = try container.decodeIfPresent(String.self, forKey: .user)
    password = try Self.reference(in: container, forKey: .password)
    policy = try container.decodeIfPresent(Policy.self, forKey: .policy) ?? policy
    workerDirectory = try container.decodeIfPresent(String.self, forKey: .workerDirectory)
    if let broken = loginRuleError() {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: broken))
    }
  }

  /// The secret of `key`, which must be a `keychain:<name>` reference.
  ///
  /// - Parameters:
  ///   - container: The container of the section.
  ///   - key: The key of the secret.
  /// - Returns: The reference, or `nil` when the key is absent.
  /// - Throws: `DecodingError` for a literal secret.
  private static func reference(
    in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
  ) throws -> ConfiguredSecret? {
    let secret = try container.decodeIfPresent(ConfiguredSecret.self, forKey: key)
    guard let secret, secret.reference == nil else {
      return secret
    }
    throw DecodingError.dataCorruptedError(
      forKey: key, in: container,
      debugDescription:
        "\(keyPath(of: key)) takes only a \(ConfiguredSecret.referencePrefix)<name> reference: "
        + "put the secret in the Keychain and give its name")
  }

  /// The text of the first login rule that the keys break, or `nil` when they keep each rule.
  ///
  /// - Returns: The text, which names the keys.
  private func loginRuleError() -> String? {
    let present = Set(CodingKeys.allCases.filter(isPresent))
    func missingPair(_ pairs: [(key: CodingKeys, needs: CodingKeys)]) -> String? {
      pairs.first { present.contains($0.key) && !present.contains($0.needs) }
        .map { "\(Self.keyPath(of: $0.key)) needs \(Self.keyPath(of: $0.needs))" }
    }
    if let missing = missingPair([(.password, .user), (.user, .password)]) {
      return missing
    }
    if present.contains(.password), let other = Self.sshLoginKeys.first(where: present.contains) {
      return "\(Self.keyPath(of: .password)) cannot be used with \(Self.keyPath(of: other)): "
        + "a password login and an SSH login are two modes"
    }
    return missingPair([(.sshKeyPassphrase, .sshKey)])
  }

  /// Whether the section sets a key of a login.
  ///
  /// - Parameter key: The key.
  /// - Returns: `true` when the key of a login has a value; `false` for each other key.
  private func isPresent(_ key: CodingKeys) -> Bool {
    switch key {
    case .sshKey: sshKey != nil
    case .sshKeyPassphrase: sshKeyPassphrase != nil
    case .adminPassword: adminPassword != nil
    case .user: user != nil
    case .password: password != nil
    case .enabled, .hosts, .policy, .workerDirectory: false
    }
  }

  /// The dotted key path of a key of the section, for the errors.
  ///
  /// - Parameter key: The key.
  /// - Returns: The key path, such as `cluster.password`.
  private static func keyPath(of key: CodingKeys) -> String {
    sectionKey + LoadedConfiguration.keyPathSeparator + key.stringValue
  }

  /// This section with each login secret resolved through `store`.
  ///
  /// - Parameter store: The secret store of the loader.
  /// - Returns: The section, whose secrets have their values.
  /// - Throws: ``ConfigurationError/unresolvedSecret(keyPath:reference:)`` for a reference with
  ///   no value; the error of the store for a reference it cannot read.
  func resolvingSecrets(through store: any SecretStore) throws -> ClusterConfiguration {
    func resolved(_ secret: ConfiguredSecret?, _ key: CodingKeys) throws -> ConfiguredSecret? {
      guard let secret, let name = secret.reference else {
        return secret
      }
      guard let value = try store.value(forReference: name) else {
        throw ConfigurationError.unresolvedSecret(keyPath: Self.keyPath(of: key), reference: name)
      }
      return ConfiguredSecret(reference: name, value: value)
    }
    var section = self
    section.sshKeyPassphrase = try resolved(sshKeyPassphrase, .sshKeyPassphrase)
    section.adminPassword = try resolved(adminPassword, .adminPassword)
    section.password = try resolved(password, .password)
    return section
  }

  /// The cluster mode of the Router: `.off` when the section is not enabled; a password login
  /// when ``password`` is set; else an SSH login with the key file of ``sshKey`` and its
  /// passphrase, or with the SSH agent and `~/.ssh` when there is no key file, and with the
  /// admin password.
  ///
  /// - Throws: ``ConfigurationError/unresolvedSecret(keyPath:reference:)`` for a login secret
  ///   with no value: a section that ``ConfigurationLoader/loadUserCluster()`` did not resolve.
  public var mode: ClusterMode {
    get throws {
      guard enabled else {
        return .off
      }
      if let user, let password {
        return .password(user: user, password: try Self.clusterSecret(password, .password))
      }
      let passphrase = try sshKeyPassphrase.map { try Self.clusterSecret($0, .sshKeyPassphrase) }
      return .ssh(
        key: sshKey.map { .file(Self.fileURL(of: $0), passphrase: passphrase) },
        adminPassword: try adminPassword.map { try Self.clusterSecret($0, .adminPassword) })
    }
  }

  /// The cluster secret of the value of a resolved secret.
  ///
  /// - Parameters:
  ///   - secret: The secret.
  ///   - key: The key of the secret, for the error.
  /// - Returns: The cluster secret.
  /// - Throws: ``ConfigurationError/unresolvedSecret(keyPath:reference:)`` when the secret has no
  ///   value.
  private static func clusterSecret(_ secret: ConfiguredSecret, _ key: CodingKeys) throws
    -> ClusterSecret
  {
    guard let value = secret.value else {
      throw ConfigurationError.unresolvedSecret(
        keyPath: keyPath(of: key), reference: secret.reference ?? "")
    }
    return ClusterSecret(value)
  }

  /// The cluster options of the Router: the hosts, the policy and the worker build. Fast synch
  /// keeps the default of `ClusterOptions`, which is on.
  public var options: ClusterOptions {
    ClusterOptions(
      hosts: hosts, policy: policy.clusterPolicy,
      workerSource: workerDirectory.map { .directory(Self.fileURL(of: $0)) } ?? .bundled())
  }

  /// The file URL of a path of the section, with a `~` at the start expanded to the home folder.
  ///
  /// - Parameter path: The path.
  /// - Returns: The file URL.
  private static func fileURL(of path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
  }
}

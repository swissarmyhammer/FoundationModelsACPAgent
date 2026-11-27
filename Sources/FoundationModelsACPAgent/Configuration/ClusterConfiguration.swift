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
/// The file holds no password and no key text, only the path of a key file: `ClusterMode` is not
/// `Codable` on purpose. A `~` at the start of a path is the home folder of the user.
public struct ClusterConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The key of the section in the root of `config.yaml`.
  public static let sectionKey = AgentConfiguration.CodingKeys.cluster.stringValue

  /// The help of the section, for the `settings` tool.
  public static let help =
    "The key paths [\"cluster\", <key>] set the Mac cluster of the Router, at the user level only "
    + "(the agent ignores a session level), and apply at the next launch: enabled (true or false), "
    + "hosts (a list of host names; absent browses with Bonjour), sshKey (the path of a key file; "
    + "absent uses the SSH agent and ~/.ssh), policy (whenFaster, whenNeeded or always) and "
    + "workerDirectory (the folder of fmcluster-worker and mlx.metallib; absent uses the worker "
    + "bundled in the app)."

  /// When true, the Router may run a model across the Macs. When false, each model runs on this
  /// Mac (`ClusterMode.off`).
  public var enabled = false

  /// The host names of the Macs, or `nil` to find them with Bonjour.
  public var hosts: [String]?

  /// The path of the SSH key file that logs in to the Macs, or `nil` for the SSH agent and the
  /// keys in `~/.ssh`.
  public var sshKey: String?

  /// When the Router splits a model across the Macs.
  public var policy = Policy.whenFaster

  /// The folder that holds `fmcluster-worker` and `mlx.metallib`, or `nil` for the worker bundled
  /// in the app.
  public var workerDirectory: String?

  /// The YAML spelling of each key.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case enabled, hosts, sshKey, policy, workerDirectory
  }

  /// The `policy` key: when the Router splits a model across the Macs.
  public enum Policy: String, Codable, CaseIterable, Sendable {
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

    /// Decodes one policy word, in any case, as `theme` and `keymap` decode.
    ///
    /// - Parameter decoder: The decoder of the value.
    /// - Throws: `DecodingError` that names the choices when the word is not a policy.
    public init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      let word = try container.decode(String.self)
      guard let policy = Self.allCases.first(where: { $0.rawValue.lowercased() == word.lowercased() })
      else {
        let choices = Self.allCases.map(\.rawValue).joined(separator: ", ")
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription:
            "\(ClusterConfiguration.sectionKey).\(CodingKeys.policy.stringValue) must be one of: "
            + "\(choices) (got \"\(word)\")")
      }
      self = policy
    }
  }

  /// The default: the cluster is off.
  public init() {}

  /// Decodes each present key and keeps the default for each absent one.
  ///
  /// - Parameter decoder: The decoder of the section.
  /// - Throws: `DecodingError` when a key has the wrong type or `policy` is not a policy.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    hosts = try container.decodeIfPresent([String].self, forKey: .hosts)
    sshKey = try container.decodeIfPresent(String.self, forKey: .sshKey)
    policy = try container.decodeIfPresent(Policy.self, forKey: .policy) ?? policy
    workerDirectory = try container.decodeIfPresent(String.self, forKey: .workerDirectory)
  }

  /// The cluster mode of the Router: `.off` when the section is not enabled, else an SSH login
  /// with the key file of ``sshKey``, or with the SSH agent and `~/.ssh` when there is none.
  public var mode: ClusterMode {
    guard enabled else {
      return .off
    }
    return .ssh(key: sshKey.map { .file(Self.fileURL(of: $0)) })
  }

  /// The cluster options of the Router: the hosts, the policy and the worker build.
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

import FoundationModelsACPAgent
import FoundationModelsExtras

/// The one parse of a `cluster:` section in the tests (task ^j1vfmkf): the cluster suites decode
/// their `config.yaml` text through it, so a change of the decode path is made in one place.
enum ClusterYAML {
  /// The `cluster` section of a `config.yaml` text, decoded as the loader decodes it.
  ///
  /// - Parameter yaml: The `config.yaml` text.
  /// - Returns: The section; the default when the text has no `cluster:` section.
  /// - Throws: The parse or the decode error.
  static func cluster(of yaml: String) throws -> ClusterConfiguration {
    try YAMLValue.parse(yaml).decoded(as: AgentConfiguration.self).cluster
  }
}

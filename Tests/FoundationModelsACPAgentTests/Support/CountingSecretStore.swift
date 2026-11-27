import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport

/// A secret store that counts its reads and gives one value for each reference. It is an
/// in-memory test double: no test that uses it touches the real Keychain.
struct CountingSecretStore: SecretStore {
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

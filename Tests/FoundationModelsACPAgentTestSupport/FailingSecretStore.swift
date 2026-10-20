import FoundationModelsACPAgent
import Security

/// A ``SecretStore`` whose every lookup throws, as a Keychain that refuses
/// the lookup does. It is an in-memory test double: no test that uses it
/// touches the real Keychain.
public struct FailingSecretStore: SecretStore {
    /// Makes a store whose every lookup throws.
    public init() {}

    /// Throws ``SecretStoreError/keychainFailure(reference:status:)`` with
    /// the status of a refused authorization.
    ///
    /// - Parameter name: The reference name.
    /// - Returns: Never returns.
    /// - Throws: The Keychain failure for `name`.
    public func value(forReference name: String) throws -> String? {
        throw SecretStoreError.keychainFailure(reference: name, status: errSecAuthFailed)
    }
}

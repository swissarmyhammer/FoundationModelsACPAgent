import Foundation
import FoundationModelsACPAgentTestSupport
import Security
import Testing

@testable import FoundationModelsACPAgent

/// The secret store port of ACPA-18 (task ^y5zy1hz): `SecretStore`, its
/// Keychain implementation `KeychainSecretStore`, and `InMemorySecretStore`.
///
/// A secret in `config.yaml` is a reference `keychain:<name>`. The agent
/// gets the value of the reference from its `SecretStore`. The host gives
/// the store to `ComposedAgent.compose(secretStore:)` and to
/// `RoutedACPAgent.init(secretStore:)`. With no store, the agent uses the
/// login Keychain under the service of its dotfolder name.
///
/// No test of this suite uses the Keychain. The Keychain round-trip test is
/// `KeychainSecretStoreTests` in the `IntegrationTests/` package.
@Suite struct SecretStoreTests {
    // MARK: - Constants

    /// The reference name that each store of this suite knows.
    private static let knownReference = "search-provider"

    /// The reference name that no store of this suite knows.
    private static let unknownReference = "no-such-reference"

    /// The value of ``knownReference``. It is a placeholder, not a key.
    private static let knownValue = "placeholder-secret-value"

    /// The dotfolder name of the compositions of this suite.
    private static let dotfolderName = "secret-store-host"

    // MARK: - InMemorySecretStore

    /// The in-memory store gives the value of a known name, and nil for an
    /// unknown name.
    @Test func theInMemoryStoreGivesTheValueOfAKnownNameAndNilForAnUnknownName() throws {
        let store = InMemorySecretStore([Self.knownReference: Self.knownValue])

        #expect(try store.value(forReference: Self.knownReference) == Self.knownValue)
        #expect(try store.value(forReference: Self.unknownReference) == nil)
    }

    /// No text form of the in-memory store shows a value: not
    /// `description`, not `debugDescription`, not the mirror that `dump`
    /// reads.
    @Test func theInMemoryStoreShowsNoValueInItsTextForms() {
        let store = InMemorySecretStore([Self.knownReference: Self.knownValue])
        let mirrorText = Mirror(reflecting: store).children
            .map { String(reflecting: $0.value) }
            .joined()

        #expect(!store.description.contains(Self.knownValue))
        #expect(!store.debugDescription.contains(Self.knownValue))
        #expect(!String(describing: store).contains(Self.knownValue))
        #expect(!String(reflecting: store).contains(Self.knownValue))
        #expect(mirrorText.contains(Self.knownReference))
        #expect(!mirrorText.contains(Self.knownValue))
    }

    // MARK: - KeychainSecretStore

    /// The Keychain store keeps the service and the Keychain that the host
    /// gave.
    @Test func theKeychainStoreKeepsItsServiceAndItsKeychain() {
        let store = KeychainSecretStore(service: Self.dotfolderName, synchronizable: true)

        #expect(store.service == Self.dotfolderName)
        #expect(store.synchronizable)
    }

    // MARK: - SecretStoreError

    /// A store error names the reference and the status, and holds no
    /// value: the error has no field for one.
    @Test func aStoreErrorNamesTheReference() {
        let failure = SecretStoreError.keychainFailure(
            reference: Self.knownReference, status: errSecInteractionNotAllowed)
        let undecodable = SecretStoreError.undecodableValue(reference: Self.knownReference)

        #expect(failure.description.contains(Self.knownReference))
        #expect(failure.description.contains(String(errSecInteractionNotAllowed)))
        #expect(undecodable.description.contains(Self.knownReference))
    }

    // MARK: - The composition

    /// `ComposedAgent.compose(secretStore:)` gives the store of the host to
    /// the agent.
    @Test func theCompositionKeepsTheStoreOfTheHost() async throws {
        let store = InMemorySecretStore([Self.knownReference: Self.knownValue])

        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "SecretStoreTests-given", secretStore: store)

        #expect(composed.agent.secretStore as? InMemorySecretStore == store)
    }

    /// With no store, the composition gives the agent the login Keychain
    /// under the service of the dotfolder name.
    @Test func theCompositionDefaultsToTheLoginKeychainOfTheDotfolderName() async throws {
        let composed = try await composeStubAgent(
            name: Self.dotfolderName, label: "SecretStoreTests-default")

        #expect(
            composed.agent.secretStore as? KeychainSecretStore
                == KeychainSecretStore(service: Self.dotfolderName, synchronizable: false))
    }
}

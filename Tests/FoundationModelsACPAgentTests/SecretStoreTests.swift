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

    /// The environment variable that roots the user configuration layer. The
    /// suite sets it, so no composition touches the real home directory.
    private static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The prefix of the unique Keychain service of the Keychain test. The
    /// test adds its item under this prefix and a new UUID, thus it never
    /// touches an item of a real host.
    private static let keychainTestServicePrefix = "acp-agent-secret-store-test-"

    /// The Keychain statuses that tell that the test host has no Keychain
    /// access. With one of them, the Keychain test is skipped, not failed.
    private static let noKeychainAccessStatuses: Set<OSStatus> = [
        errSecMissingEntitlement,
        errSecInteractionNotAllowed,
        errSecNotAvailable,
        errSecNoSuchKeychain,
        errSecAuthFailed,
    ]

    // MARK: - InMemorySecretStore

    /// The in-memory store gives the value of a known name, and nil for an
    /// unknown name.
    @Test func theInMemoryStoreGivesTheValueOfAKnownNameAndNilForAnUnknownName() throws {
        let store = InMemorySecretStore([Self.knownReference: Self.knownValue])

        #expect(try store.value(forReference: Self.knownReference) == Self.knownValue)
        #expect(try store.value(forReference: Self.unknownReference) == nil)
    }

    /// No text form of the in-memory store shows a value: not
    /// `description`, not `debugDescription`, not `dump`.
    @Test func theInMemoryStoreShowsNoValueInItsTextForms() {
        let store = InMemorySecretStore([Self.knownReference: Self.knownValue])
        var dumped = ""
        dump(store, to: &dumped)

        #expect(!store.description.contains(Self.knownValue))
        #expect(!store.debugDescription.contains(Self.knownValue))
        #expect(!String(describing: store).contains(Self.knownValue))
        #expect(!String(reflecting: store).contains(Self.knownValue))
        #expect(!dumped.contains(Self.knownValue))
    }

    // MARK: - KeychainSecretStore

    /// The Keychain store with `synchronizable: false` reads an item of the
    /// login Keychain that `SecItemAdd` added under a unique test service,
    /// and gives nil after the delete of that item.
    @Test func theLoginKeychainStoreReadsAnAddedItem() throws {
        let service = Self.keychainTestServicePrefix + UUID().uuidString
        let addStatus = Self.addLoginKeychainItem(
            service: service, account: Self.knownReference, value: Self.knownValue)
        if Self.noKeychainAccessStatuses.contains(addStatus) {
            try Test.cancel(
                "the test host has no Keychain access: SecItemAdd gave status \(addStatus)")
        }
        try #require(addStatus == errSecSuccess, "SecItemAdd gave status \(addStatus)")
        defer { Self.deleteLoginKeychainItem(service: service, account: Self.knownReference) }
        let store = KeychainSecretStore(service: service, synchronizable: false)

        #expect(try store.value(forReference: Self.knownReference) == Self.knownValue)
        #expect(try store.value(forReference: Self.unknownReference) == nil)
    }

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

        let composed = try await Self.composeStubAgent(
            label: "SecretStoreTests-given", secretStore: store)

        #expect(composed.agent.secretStore as? InMemorySecretStore == store)
    }

    /// With no store, the composition gives the agent the login Keychain
    /// under the service of the dotfolder name.
    @Test func theCompositionDefaultsToTheLoginKeychainOfTheDotfolderName() async throws {
        let composed = try await Self.composeStubAgent(
            label: "SecretStoreTests-default", secretStore: nil)

        #expect(
            composed.agent.secretStore as? KeychainSecretStore
                == KeychainSecretStore(service: Self.dotfolderName, synchronizable: false))
    }

    // MARK: - Helpers

    /// Composes the agent over the stub model, with each configuration root
    /// in a throwaway directory.
    ///
    /// - Parameters:
    ///   - label: The directory label, so a leftover directory says where it
    ///     came from.
    ///   - secretStore: The store to give to the composition, or nil for the
    ///     default.
    /// - Returns: The composition.
    /// - Throws: Whatever the composition throws.
    private static func composeStubAgent(
        label: String, secretStore: (any SecretStore)?
    ) async throws -> ComposedAgent {
        let configHome = makeResolvedDirectory(label: "\(label)-config")
        let workspace = makeResolvedDirectory(label: "\(label)-repo")
        let environment = try StubAgentDefaultsLayer.makeEnvironment(
            name: dotfolderName, base: [configHomeVariable: configHome.path])
        return try await ComposedAgent.compose(
            name: DotfolderName(dotfolderName),
            workingDirectory: workspace,
            environment: environment,
            modelSource: .stub,
            secretStore: secretStore)
    }

    /// The query attributes of one generic password item of the login
    /// Keychain.
    ///
    /// - Parameters:
    ///   - service: The service of the item.
    ///   - account: The account of the item.
    /// - Returns: The query attributes.
    private static func loginKeychainItemQuery(
        service: String, account: String
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanFalse as Any,
        ]
    }

    /// Adds one generic password item to the login Keychain.
    ///
    /// - Parameters:
    ///   - service: The service of the item.
    ///   - account: The account of the item.
    ///   - value: The value of the item.
    /// - Returns: The status of `SecItemAdd`.
    private static func addLoginKeychainItem(
        service: String, account: String, value: String
    ) -> OSStatus {
        var attributes = loginKeychainItemQuery(service: service, account: account)
        attributes[kSecValueData] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Deletes one generic password item of the login Keychain.
    ///
    /// - Parameters:
    ///   - service: The service of the item.
    ///   - account: The account of the item.
    private static func deleteLoginKeychainItem(service: String, account: String) {
        SecItemDelete(loginKeychainItemQuery(service: service, account: account) as CFDictionary)
    }
}

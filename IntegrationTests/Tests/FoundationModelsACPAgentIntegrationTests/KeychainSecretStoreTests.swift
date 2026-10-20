import Foundation
import Security
import Testing

@testable import FoundationModelsACPAgent

/// `KeychainSecretStore` against the real login Keychain of the test host
/// (ACPA-18, task ^y5zy1hz).
///
/// This suite uses a real external system, the Keychain, thus it is an
/// integration suite and not a unit suite. The host of this suite must give
/// Keychain access. When `SecItemAdd` fails, the test fails with the status.
@Suite struct KeychainSecretStoreTests {
    /// The reference name of the item that the test adds.
    private static let addedReference = "search-provider"

    /// The reference name that no item of the test service has.
    private static let unknownReference = "no-such-reference"

    /// The value of ``addedReference``. It is a placeholder, not a key.
    private static let addedValue = "placeholder-secret-value"

    /// The prefix of the unique Keychain service of the test. The test adds
    /// its item under this prefix and a new UUID, thus it never touches an
    /// item of a real host.
    private static let testServicePrefix = "acp-agent-secret-store-test-"

    /// The Keychain store with `synchronizable: false` reads an item of the
    /// login Keychain that `SecItemAdd` added under a unique test service,
    /// and gives nil for a name with no item.
    @Test func theLoginKeychainStoreReadsAnAddedItem() throws {
        let store = KeychainSecretStore(
            service: Self.testServicePrefix + UUID().uuidString, synchronizable: false)
        let addStatus = Self.addItem(
            of: store, account: Self.addedReference, value: Self.addedValue)
        try #require(addStatus == errSecSuccess, "SecItemAdd gave status \(addStatus)")
        defer { Self.deleteItem(of: store, account: Self.addedReference) }

        #expect(try store.value(forReference: Self.addedReference) == Self.addedValue)
        #expect(try store.value(forReference: Self.unknownReference) == nil)
    }

    // MARK: - Helpers

    /// Adds one generic password item to the Keychain of `store`, with the
    /// query attributes that `store` reads.
    ///
    /// - Parameters:
    ///   - store: The store whose service and Keychain the item gets.
    ///   - account: The account of the item: the reference name.
    ///   - value: The value of the item.
    /// - Returns: The status of `SecItemAdd`.
    private static func addItem(
        of store: KeychainSecretStore, account: String, value: String
    ) -> OSStatus {
        var attributes = store.itemQuery(account: account)
        attributes[kSecValueData] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Deletes one generic password item of the Keychain of `store`.
    ///
    /// - Parameters:
    ///   - store: The store whose service and Keychain hold the item.
    ///   - account: The account of the item: the reference name.
    private static func deleteItem(of store: KeychainSecretStore, account: String) {
        SecItemDelete(store.itemQuery(account: account) as CFDictionary)
    }
}

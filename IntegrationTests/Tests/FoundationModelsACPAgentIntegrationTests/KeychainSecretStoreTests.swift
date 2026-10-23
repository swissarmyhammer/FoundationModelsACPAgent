import Foundation
import Security
import Testing

@testable import FoundationModelsACPAgent

/// `KeychainSecretStore` against a real Keychain file (ACPA-18, task
/// ^y5zy1hz; task ^9ffd1hf).
///
/// This suite uses a real external system, the Keychain, thus it is an
/// integration suite and not a unit suite. Each test makes a Keychain of its
/// own (``TemporaryKeychain``) and gives it to the store, so the suite never
/// uses the login Keychain, which is locked on the self-hosted CI runner, and
/// never changes the user's Keychain search list.
@Suite struct KeychainSecretStoreTests {
    /// The reference name of the item that the test adds.
    private static let addedReference = "search-provider"

    /// The reference name that no item of the test service has.
    private static let unknownReference = "no-such-reference"

    /// The value of ``addedReference``. It is a placeholder, not a key.
    private static let addedValue = "placeholder-secret-value"

    /// The prefix of the unique Keychain service of the test.
    private static let testServicePrefix = "acp-agent-secret-store-test-"

    /// A store over a temporary Keychain file reads an item that
    /// `SecItemAdd` added to that Keychain, and gives nil for a name with no
    /// item. The user's Keychain search list is the same after the test as
    /// before it.
    @Test func aStoreOverATemporaryKeychainReadsAnAddedItem() async throws {
        let searchListBefore = try await TemporaryKeychain.userSearchList()
        let keychain = try await TemporaryKeychain.make()
        defer { await Self.delete(keychain) }
        let store = KeychainSecretStore(
            service: Self.testServicePrefix + UUID().uuidString, synchronizable: false,
            keychain: .file(keychain.file))

        let addStatus = try Self.addItem(
            of: store, account: Self.addedReference, value: Self.addedValue)

        try #require(addStatus == errSecSuccess, "SecItemAdd gave status \(addStatus)")
        #expect(try store.value(forReference: Self.addedReference) == Self.addedValue)
        #expect(try store.value(forReference: Self.unknownReference) == nil)
        #expect(try await TemporaryKeychain.userSearchList() == searchListBefore)
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
    /// - Throws: The error of the store's query.
    private static func addItem(
        of store: KeychainSecretStore, account: String, value: String
    ) throws -> OSStatus {
        var attributes = try store.itemQuery(account: account)
        attributes[kSecValueData] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Deletes `keychain` and its folder, and records a failure as an issue
    /// of the test.
    ///
    /// - Parameter keychain: The Keychain of the test.
    private static func delete(_ keychain: TemporaryKeychain) async {
        do {
            try await keychain.delete()
        } catch {
            Issue.record(error, "the temporary Keychain was not deleted")
        }
    }
}

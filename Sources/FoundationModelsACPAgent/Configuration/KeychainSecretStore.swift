import Foundation
import Security

/// A ``SecretStore`` over the generic password items of a Keychain
/// (ACPA-18, D101).
///
/// The store reads the item whose service is ``service`` and whose account is
/// the reference name. ``synchronizable`` selects the Keychain:
///
/// - `true`: the synchronizable items of iCloud Keychain. The app uses
///   this Keychain.
/// - `false`: the login Keychain, with no synchronizable item and with the
///   data protection Keychain off. The CLI uses this Keychain.
///
/// The store holds no value, thus each text form of it shows the service and
/// the Keychain choice only.
public struct KeychainSecretStore: SecretStore, Equatable {
    /// The service attribute (`kSecAttrService`) of each item of the store.
    public let service: String

    /// Whether the store reads the synchronizable items of iCloud Keychain
    /// (`true`), or the login Keychain (`false`).
    public let synchronizable: Bool

    /// Makes a store over one service of one Keychain.
    ///
    /// - Parameters:
    ///   - service: The service attribute of each item.
    ///   - synchronizable: `true` for the synchronizable items of iCloud
    ///     Keychain, `false` for the login Keychain.
    public init(service: String, synchronizable: Bool) {
        self.service = service
        self.synchronizable = synchronizable
    }

    /// Reads the generic password item of `name` under ``service``.
    ///
    /// - Parameter name: The reference name: the account attribute of the
    ///   item.
    /// - Returns: The value of the item, or `nil` when the Keychain has no
    ///   item for `name`.
    /// - Throws: ``SecretStoreError/keychainFailure(reference:status:)`` for
    ///   each other Keychain status, and
    ///   ``SecretStoreError/undecodableValue(reference:)`` when the data of
    ///   the item is not UTF-8 text. Each error names only `name`.
    public func value(forReference name: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookupQuery(account: name) as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailure(reference: name, status: status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.undecodableValue(reference: name)
        }
        return value
    }

    /// The attributes that identify one item of this store: the class, the
    /// service, the account and the Keychain. The query has no key for the
    /// data that a lookup gives back.
    ///
    /// The lookup of this store and the Keychain integration test both use
    /// this query, thus the item that the test adds and the item that the
    /// store reads always have the same attributes.
    ///
    /// - Parameter account: The account attribute of the item: the reference
    ///   name.
    /// - Returns: The attributes for `SecItemAdd`, `SecItemDelete`, or the
    ///   start of a lookup query.
    func itemQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable,
        ]
        if !synchronizable {
            query[kSecUseDataProtectionKeychain] = false
        }
        return query
    }

    /// The query of one item of this store, and of its data.
    ///
    /// - Parameter account: The account attribute of the item: the reference
    ///   name.
    /// - Returns: The query attributes for `SecItemCopyMatching`.
    private func lookupQuery(account: String) -> [CFString: Any] {
        var query = itemQuery(account: account)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        return query
    }
}

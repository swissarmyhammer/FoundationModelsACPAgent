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
/// - `false`: a file-based Keychain, with no synchronizable item and with the
///   data protection Keychain off. ``keychain`` names the file: the login
///   Keychain by default, which the CLI uses, or a Keychain file of its own,
///   which a test uses.
///
/// The store holds no value, thus each text form of it shows the service and
/// the Keychain choice only.
public struct KeychainSecretStore: SecretStore, Equatable {
    /// The file-based Keychain of a store with `synchronizable: false`.
    public enum Keychain: Equatable, Sendable {
        /// The login Keychain: the query names no Keychain, thus a lookup
        /// reads the user's default Keychain search list.
        case login

        /// The Keychain file at a URL, such as a temporary Keychain that a
        /// test made. The query names this Keychain alone, thus no lookup
        /// reads the login Keychain.
        case file(URL)
    }

    /// The service attribute (`kSecAttrService`) of each item of the store.
    public let service: String

    /// Whether the store reads the synchronizable items of iCloud Keychain
    /// (`true`), or a file-based Keychain (`false`).
    public let synchronizable: Bool

    /// The file-based Keychain of the store. It is ``Keychain/login`` for a
    /// store with `synchronizable: true`.
    public let keychain: Keychain

    /// Makes a store over one service of one Keychain.
    ///
    /// - Parameters:
    ///   - service: The service attribute of each item.
    ///   - synchronizable: `true` for the synchronizable items of iCloud
    ///     Keychain, `false` for the file-based Keychain `keychain`.
    ///   - keychain: The file-based Keychain of a store with
    ///     `synchronizable: false`: the login Keychain by default. A
    ///     synchronizable item lives in no Keychain file, thus a store with
    ///     `synchronizable: true` takes ``Keychain/login`` only.
    public init(service: String, synchronizable: Bool, keychain: Keychain = .login) {
        precondition(
            !synchronizable || keychain == .login,
            "a synchronizable Keychain store reads iCloud Keychain, never a Keychain file")
        self.service = service
        self.synchronizable = synchronizable
        self.keychain = keychain
    }

    /// The default store of a host that gives no store: the login Keychain
    /// under the service `name`. The agent and its configuration loader
    /// both use it, thus the two read the same items.
    ///
    /// - Parameter name: The dotfolder name of the host.
    /// - Returns: The store over the login Keychain.
    public static func loginKeychain(for name: DotfolderName) -> KeychainSecretStore {
        KeychainSecretStore(service: name.rawValue, synchronizable: false)
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
        let status = SecItemCopyMatching(try lookupQuery(account: name) as CFDictionary, &result)
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
    /// For a ``Keychain/file(_:)`` Keychain, the query names that Keychain
    /// twice: as `kSecUseKeychain`, the Keychain that `SecItemAdd` adds to,
    /// and as the only Keychain of `kSecMatchSearchList`, the search list of
    /// `SecItemCopyMatching` and `SecItemDelete`.
    ///
    /// The lookup of this store and the Keychain integration test both use
    /// this query, thus the item that the test adds and the item that the
    /// store reads always have the same attributes.
    ///
    /// - Parameter account: The account attribute of the item: the reference
    ///   name.
    /// - Returns: The attributes for `SecItemAdd`, `SecItemDelete`, or the
    ///   start of a lookup query.
    /// - Throws: ``SecretStoreError/keychainFailure(reference:status:)`` when
    ///   the Keychain file cannot be opened. The error names only `account`.
    func itemQuery(account: String) throws -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable,
        ]
        if !synchronizable {
            query[kSecUseDataProtectionKeychain] = false
        }
        if let fileKeychain = try keychain.makeSecKeychain(forReference: account) {
            query[kSecUseKeychain] = fileKeychain
            query[kSecMatchSearchList] = [fileKeychain]
        }
        return query
    }

    /// The query of one item of this store, and of its data.
    ///
    /// - Parameter account: The account attribute of the item: the reference
    ///   name.
    /// - Returns: The query attributes for `SecItemCopyMatching`.
    /// - Throws: The error of ``itemQuery(account:)``.
    private func lookupQuery(account: String) throws -> [CFString: Any] {
        var query = try itemQuery(account: account)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        return query
    }
}

extension KeychainSecretStore.Keychain {
    /// The `SecKeychain` that a query names for this Keychain.
    ///
    /// Opening a `SecKeychain` reads no file and asks for no password: a
    /// lookup through it reads the file, and fails then when the file is
    /// missing or locked.
    ///
    /// - Parameter name: The secret reference name that an error names.
    /// - Returns: `nil` for ``login``, whose query names no Keychain, and the
    ///   `SecKeychain` of the file for ``file(_:)``.
    /// - Throws: ``SecretStoreError/keychainFailure(reference:status:)`` when
    ///   the file cannot be opened.
    func makeSecKeychain(forReference name: String) throws -> SecKeychain? {
        switch self {
        case .login:
            return nil
        case .file(let url):
            let opener: any KeychainFileOpening = SecKeychainFileOpener()
            var fileKeychain: SecKeychain?
            let status = opener.openKeychain(atPath: url.path, into: &fileKeychain)
            guard status == errSecSuccess else {
                throw SecretStoreError.keychainFailure(reference: name, status: status)
            }
            guard let fileKeychain else {
                throw SecretStoreError.keychainFailure(reference: name, status: errSecNoSuchKeychain)
            }
            return fileKeychain
        }
    }
}

/// Opens a Keychain file as a `SecKeychain` reference.
///
/// The one way to name a Keychain file in a `SecItem` query is a `SecKeychain`
/// reference (`kSecUseKeychain`, `kSecMatchSearchList`), and the one way to
/// get a reference to a file is `SecKeychainOpen`, which macOS 10.10
/// deprecated. The data protection Keychain, which has no deprecated API,
/// keeps no Keychain file, thus it cannot stand in.
///
/// The deprecated call stands in one place: ``SecKeychainFileOpener``, whose
/// witness is itself marked deprecated, so the call inside it gives no
/// warning. A caller reaches it through this protocol, whose requirement is
/// not deprecated, so the call site gives no warning either.
private protocol KeychainFileOpening {
    /// Opens the Keychain file at `path`.
    ///
    /// - Parameters:
    ///   - path: The absolute path of the Keychain file.
    ///   - reference: Set to the reference of the file on success.
    /// - Returns: The status of the open.
    func openKeychain(atPath path: String, into reference: inout SecKeychain?) -> OSStatus
}

/// The ``KeychainFileOpening`` over `SecKeychainOpen`.
private struct SecKeychainFileOpener: KeychainFileOpening {
    /// Opens the Keychain file at `path` with `SecKeychainOpen`.
    ///
    /// The mark matches the deprecation of `SecKeychainOpen`, which keeps the
    /// call below free of a warning. See ``KeychainFileOpening``.
    ///
    /// - Parameters:
    ///   - path: The absolute path of the Keychain file.
    ///   - reference: Set to the reference of the file on success.
    /// - Returns: The status of `SecKeychainOpen`.
    @available(macOS, deprecated: 10.10, message: "SecKeychainOpen is deprecated; call through KeychainFileOpening")
    func openKeychain(atPath path: String, into reference: inout SecKeychain?) -> OSStatus {
        SecKeychainOpen(path, &reference)
    }
}

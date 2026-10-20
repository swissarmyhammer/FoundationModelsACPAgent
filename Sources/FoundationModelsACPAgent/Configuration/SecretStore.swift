import Foundation

/// The port that gives the value of a secret reference (ACPA-18, D101).
///
/// A secret in `config.yaml` is a reference `keychain:<name>`, and never the
/// value. The agent gives the `<name>` part to its store, and the store gives
/// back the value. The app gives a store over the synchronizable items of
/// iCloud Keychain. The CLI gives a store over the login Keychain
/// (``KeychainSecretStore``). A test, or a host with no Keychain, gives an
/// ``InMemorySecretStore``.
///
/// **A value never goes into a log, a `description` or an error message.** An
/// implementation names only the reference in each text form and in each
/// error.
public protocol SecretStore: Sendable {
    /// Gives the value of one secret reference.
    ///
    /// - Parameter name: The reference name: the `<name>` part of
    ///   `keychain:<name>`.
    /// - Returns: The value, or `nil` when the store has no item for `name`.
    /// - Throws: ``SecretStoreError`` when the store cannot read the item. The
    ///   error names only the reference.
    func value(forReference name: String) throws -> String?
}

/// Why a ``SecretStore`` did not give the value of a reference.
///
/// Each case names the reference and never the value: no case has a field
/// for a value.
public enum SecretStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The Keychain refused the lookup with a status other than "no item".
    case keychainFailure(reference: String, status: OSStatus)

    /// The Keychain item exists, but its data is not UTF-8 text.
    case undecodableValue(reference: String)

    /// A human-readable reason that names the reference, and never a value.
    public var description: String {
        switch self {
        case .keychainFailure(let reference, let status):
            return "the Keychain lookup of secret reference \"\(reference)\" failed with status \(status)"
        case .undecodableValue(let reference):
            return "the Keychain item of secret reference \"\(reference)\" is not UTF-8 text"
        }
    }
}

/// A ``SecretStore`` that keeps its values in memory: for tests, and for a
/// host with no Keychain.
///
/// No text form of this type shows a value. `description`,
/// `debugDescription` and `dump` show the reference names only.
public struct InMemorySecretStore: SecretStore, Equatable {
    /// The values, keyed by the reference name.
    private let values: [String: String]

    /// Makes a store over a fixed set of values.
    ///
    /// - Parameter values: The values, keyed by the reference name. Empty by
    ///   default.
    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    /// Gives the value of `name`, or `nil` when the store has no value for
    /// it. It never throws.
    ///
    /// - Parameter name: The reference name.
    /// - Returns: The value, or `nil`.
    public func value(forReference name: String) throws -> String? {
        values[name]
    }
}

extension InMemorySecretStore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The sorted reference names of the store. It never shows a value.
    private var referenceNames: [String] {
        values.keys.sorted()
    }

    /// The type name and the reference names. It never shows a value.
    public var description: String {
        "InMemorySecretStore(references: \(referenceNames))"
    }

    /// The same text as ``description``. It never shows a value.
    public var debugDescription: String {
        description
    }

    /// A mirror that holds the reference names only, thus `dump` shows no
    /// value.
    public var customMirror: Mirror {
        Mirror(self, children: ["references": referenceNames], displayStyle: .struct)
    }
}

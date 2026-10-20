import Foundation

/// One secret value of `config.yaml`, such as an API key of a search
/// provider (task ^ba231ka).
///
/// A secret has one of two forms in `config.yaml` (ACPA-18, D101):
///
/// - A reference `keychain:<name>`. The decode keeps the name and no value.
///   ``ConfigurationLoader`` then gets the value from its ``SecretStore``,
///   and keeps the reference beside the value.
/// - A literal: each other string. The string is the value.
///
/// **No form of this type shows the value.** For a reference, `description`,
/// `debugDescription`, the mirror and the `Encodable` form each give
/// `keychain:<name>`. For a literal, each gives ``redactedForm``. Thus
/// `config show`, `/config`, the `--json` tree, a log line and a span that
/// holds the configuration show the reference or `<redacted>`, and never the
/// key. The value goes to one consumer only: the code that reads ``value``
/// to give it to the capability.
///
/// The decode reads the plain value of a literal, and the encode writes the
/// redacted form. That is the one place where the two directions differ on
/// purpose: a document that the agent writes for a person to read must not
/// hold a key. A writer that puts a document into a layer gives the encoder
/// ``Swift/CodingUserInfoKey/omitsConfiguredSecrets``, and the section that
/// holds the secrets then writes no literal (see ``ConfigurationYAML``). A
/// reference holds no key, thus each document keeps it.
public struct ConfiguredSecret: Codable, Hashable, Sendable {
    /// The text that each form of a literal shows in place of the value.
    public static let redactedForm = "<redacted>"

    /// The prefix of a reference in `config.yaml`: the name follows it.
    public static let referencePrefix = "keychain:"

    /// Where the value of a secret comes from.
    private enum Source: Hashable, Sendable {
        /// The value stands in `config.yaml`.
        case literal(String)

        /// `config.yaml` holds `keychain:<name>`. The value is `nil` until
        /// the store gives it.
        case reference(name: String, value: String?)
    }

    /// The form and the value of this secret.
    private let source: Source

    /// Makes a literal secret.
    ///
    /// - Parameter value: The secret value.
    public init(_ value: String) {
        source = .literal(value)
    }

    /// Makes a reference that has no value yet.
    ///
    /// - Parameter name: The reference name: the `<name>` part of
    ///   `keychain:<name>`.
    public init(reference name: String) {
        source = .reference(name: name, value: nil)
    }

    /// Makes a reference with the value that a store gave.
    ///
    /// - Parameters:
    ///   - name: The reference name.
    ///   - value: The value of the reference.
    init(reference name: String, value: String) {
        source = .reference(name: name, value: value)
    }

    /// The secret value. Read it only to give it to its consumer. It is
    /// `nil` only for a reference that has no value yet: such a secret
    /// gives no key, and never an empty one.
    public var value: String? {
        switch source {
        case .literal(let value):
            value
        case .reference(_, let value):
            value
        }
    }

    /// The reference name, or `nil` for a literal.
    public var reference: String? {
        guard case .reference(let name, _) = source else {
            return nil
        }
        return name
    }

    /// The text that each form of this secret shows: `keychain:<name>` for a
    /// reference, and ``redactedForm`` for a literal. It never holds the
    /// value.
    var shownForm: String {
        reference.map { Self.referencePrefix + $0 } ?? Self.redactedForm
    }

    /// The text of a value that is not always a secret, such as an `env`
    /// value of an MCP server: `keychain:<name>` for a reference, and the
    /// value for a literal. It never holds the value of a reference.
    var plainForm: String {
        switch source {
        case .literal(let value):
            value
        case .reference(let name, _):
            Self.referencePrefix + name
        }
    }

    /// This secret with the value of its reference from `store`. A literal
    /// does not change.
    ///
    /// A reference with no item adds one
    /// ``ConfigurationWarning/unresolvedSecret(keyPath:reference:)`` to
    /// `warnings`. A reference whose lookup throws adds one
    /// ``ConfigurationWarning/unreadableSecret(keyPath:reference:)``. The
    /// warning does not hold the error: it names only the key path and the
    /// reference, and it never holds a value.
    ///
    /// - Parameters:
    ///   - store: The store that gives the value of the reference.
    ///   - keyPath: The dotted key path of the secret, for the warning.
    ///   - warnings: The warnings of the load.
    /// - Returns: The secret with its value, or `nil` when the store has no
    ///   item or the lookup failed.
    func resolved(
        through store: any SecretStore, keyPath: String, warnings: inout [ConfigurationWarning]
    ) -> ConfiguredSecret? {
        guard let name = reference else {
            return self
        }
        let value: String?
        do {
            value = try store.value(forReference: name)
        } catch {
            warnings.append(.unreadableSecret(keyPath: keyPath, reference: name))
            return nil
        }
        guard let value else {
            warnings.append(.unresolvedSecret(keyPath: keyPath, reference: name))
            return nil
        }
        return ConfiguredSecret(reference: name, value: value)
    }

    /// Decodes a string scalar: `keychain:<name>` is a reference with no
    /// value, and each other string is a literal value.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard text.hasPrefix(Self.referencePrefix) else {
            self.init(text)
            return
        }
        self.init(reference: String(text.dropFirst(Self.referencePrefix.count)))
    }

    /// Encodes ``shownForm``, and never the value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(shownForm)
    }
}

extension ConfiguredSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `keychain:<name>` for a reference, and ``redactedForm`` for a
    /// literal. It never shows the value.
    public var description: String { shownForm }

    /// The same text as ``description``. It never shows the value.
    public var debugDescription: String { shownForm }

    /// A mirror whose one child is `keychain:<name>` for a reference, and a
    /// mirror with no child for a literal. Thus `dump` never shows the
    /// value.
    public var customMirror: Mirror {
        let children: [Mirror.Child] = reference.map { _ in [(label: "reference", value: shownForm)] } ?? []
        return Mirror(self, children: children, displayStyle: .struct)
    }
}

extension CodingUserInfoKey {
    /// The flag that tells a section that holds ``ConfiguredSecret`` values
    /// to encode no literal of them. A writer that puts the configuration
    /// into a layer file sets it to `true`, so no key goes into a file that
    /// can be committed. A reference holds no key, thus it stays.
    public static let omitsConfiguredSecrets: CodingUserInfoKey = {
        guard let key = CodingUserInfoKey(rawValue: "omitsConfiguredSecrets") else {
            preconditionFailure("a non-empty raw value always makes a CodingUserInfoKey")
        }
        return key
    }()
}

extension Encoder {
    /// Whether this encoder writes a document for a layer file, thus a
    /// section must encode no literal ``ConfiguredSecret``.
    var omitsConfiguredSecrets: Bool {
        userInfo[.omitsConfiguredSecrets] as? Bool == true
    }

    /// The secrets of `secrets` that this encoder writes: each secret, or
    /// only the references when ``omitsConfiguredSecrets`` is set.
    ///
    /// - Parameter secrets: The secrets of a map, such as the `apiKeys` map
    ///   of the web tool or the `headers` map of an MCP server.
    /// - Returns: The secrets to encode.
    func writtenSecrets<Key>(_ secrets: [Key: ConfiguredSecret]) -> [Key: ConfiguredSecret] {
        omitsConfiguredSecrets ? secrets.filter { $0.value.reference != nil } : secrets
    }
}

extension Dictionary where Value == ConfiguredSecret {
    /// The value of each secret that has one. A reference with no value
    /// gives no entry, thus it never gives an empty value.
    var resolvedValues: [Key: String] {
        compactMapValues(\.value)
    }
}

extension Dictionary where Key == String, Value == ConfiguredSecret {
    /// This map with the value of each `keychain:<name>` reference from
    /// `store`. A literal does not change. A reference with no value is
    /// left out, and it adds one warning: see
    /// ``ConfiguredSecret/resolved(through:keyPath:warnings:)``. The
    /// warnings come in the sorted order of the keys.
    ///
    /// - Parameters:
    ///   - store: The store that gives the value of each reference.
    ///   - section: The dotted key path of the map. The key path of one
    ///     secret is the section, a dot, and the key.
    ///   - warnings: The warnings of the load.
    /// - Returns: The map with each reference resolved.
    func resolvingSecrets(
        through store: any SecretStore, section: String, warnings: inout [ConfigurationWarning]
    ) -> [String: ConfiguredSecret] {
        Dictionary(
            uniqueKeysWithValues: keys.sorted().compactMap { key in
                self[key]?
                    .resolved(
                        through: store, keyPath: section + LoadedConfiguration.keyPathSeparator + key,
                        warnings: &warnings
                    )
                    .map { (key, $0) }
            })
    }
}

import Foundation

/// One secret value of `config.yaml`, such as an API key of a search
/// provider (task ^ba231ka).
///
/// **No form of this type shows the value.** `description`,
/// `debugDescription`, `dump` and the `Encodable` form each give
/// ``redactedForm``. Thus `config show`, `/config`, the `--json` tree, a log
/// line and a span that holds the configuration show `<redacted>`, and never
/// the key. The value goes to one consumer only: the code that reads
/// ``value`` to give it to the capability.
///
/// The decode reads the plain value, and the encode writes the redacted
/// form. That is the one place where the two directions differ on purpose:
/// a document that the agent writes for a person to read must not hold a
/// key. A writer that puts a document into a layer gives the encoder
/// ``Swift/CodingUserInfoKey/omitsConfiguredSecrets``, and the section that
/// holds the secrets then writes none (see ``ConfigurationYAML``).
public struct ConfiguredSecret: Codable, Hashable, Sendable {
    /// The text that each form of a secret shows in place of the value.
    public static let redactedForm = "<redacted>"

    /// The secret value. Read it only to give it to its consumer.
    public let value: String

    /// Makes a secret.
    ///
    /// - Parameter value: The secret value.
    public init(_ value: String) {
        self.value = value
    }

    /// Decodes the plain value from a string scalar.
    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes ``redactedForm``, and never the value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.redactedForm)
    }
}

extension ConfiguredSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// ``redactedForm``. It never shows the value.
    public var description: String { Self.redactedForm }

    /// ``redactedForm``. It never shows the value.
    public var debugDescription: String { Self.redactedForm }

    /// A mirror with no children, thus `dump` shows only
    /// ``redactedForm``.
    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

extension CodingUserInfoKey {
    /// The flag that tells a section that holds ``ConfiguredSecret`` values
    /// to encode none of them. A writer that puts the configuration into a
    /// layer file sets it to `true`, so no key goes into a file that can be
    /// committed.
    public static let omitsConfiguredSecrets: CodingUserInfoKey = {
        guard let key = CodingUserInfoKey(rawValue: "omitsConfiguredSecrets") else {
            preconditionFailure("a non-empty raw value always makes a CodingUserInfoKey")
        }
        return key
    }()
}

extension Encoder {
    /// Whether this encoder writes a document for a layer file, thus a
    /// section must encode no ``ConfiguredSecret``.
    var omitsConfiguredSecrets: Bool {
        userInfo[.omitsConfiguredSecrets] as? Bool == true
    }
}

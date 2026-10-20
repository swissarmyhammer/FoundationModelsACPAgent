import Foundation
import FoundationModelsExtras

/// A settings call that the `settings` engine refuses (ACPA-17).
///
/// The `settings` endpoint and ``SettingsTool`` give each case in the
/// `errors` list of a response, with its ``code`` in `extensions.code`. The
/// ``message`` tells how to correct the call. No case holds a secret value:
/// a case names a key path or a reference only.
public enum SettingsGraphError: CodedError, Equatable {
    /// `UNKNOWN_SECTION`: the first key of the key path is not a section of
    /// the configuration. The value is that key.
    case unknownSection(key: String)

    /// `INVALID_KEY_PATH`: the store cannot take the key path, for example an
    /// empty key path, or a key on the way that holds a scalar or a list. The
    /// detail is the reason of the store.
    case invalidKeyPath(detail: String)

    /// `INVALID_CWD`: the working directory is not an absolute path. The value
    /// is the path that the call gave.
    case relativeWorkingDirectory(path: String)

    /// `SECRET_NEEDS_REFERENCE`: the call gave a value that is not a
    /// `keychain:<name>` reference for a secret key. The value is the dotted
    /// key path of the secret key.
    case secretNeedsReference(keyPath: String)

    /// `TEMPLATE_NOT_KEPT`: the file of the level holds a template construct
    /// that a write cannot keep, thus the change would lose it. The value is
    /// the dotted key path of the change.
    case templateNotKept(keyPath: String)

    /// `INVALID_VALUE`: the merged settings after the change do not pass the
    /// schema check or do not decode. The detail is the reason of the check.
    case invalidValue(detail: String)

    /// `NO_LEVEL`: the settings folders give no folder for the level. The
    /// detail is the reason of the store.
    case noLevel(detail: String)

    /// `SECRET_UNREADABLE`: the secret store cannot tell if it has an item
    /// for a reference. The value is the reference name.
    case unreadableSecret(reference: String)

    /// The code of the error, for example `UNKNOWN_SECTION`.
    public var code: String {
        switch self {
        case .unknownSection: "UNKNOWN_SECTION"
        case .invalidKeyPath: "INVALID_KEY_PATH"
        case .relativeWorkingDirectory: "INVALID_CWD"
        case .secretNeedsReference: "SECRET_NEEDS_REFERENCE"
        case .templateNotKept: "TEMPLATE_NOT_KEPT"
        case .invalidValue: "INVALID_VALUE"
        case .noLevel: "NO_LEVEL"
        case .unreadableSecret: "SECRET_UNREADABLE"
        }
    }

    /// The message of the error: what is wrong, and how to correct the call.
    public var message: String {
        switch self {
        case .unknownSection(let key):
            "\"\(key)\" is not a section of the settings. Start the key path with one of these sections: "
                + "\(SettingsEngine.sections.joined(separator: ", "))."
        case .invalidKeyPath(let detail):
            "The key path is not valid: \(detail). Name a key, and go through mappings only."
        case .relativeWorkingDirectory(let path):
            "The working directory \"\(path)\" is not an absolute path. Give the absolute path of the session folder."
        case .secretNeedsReference(let keyPath):
            "\(keyPath) is a secret key. Give a \(ConfiguredSecret.referencePrefix)<name> reference, and put the "
                + "value in the Keychain under <name>. A literal value is refused."
        case .templateNotKept(let keyPath):
            "The change of \(keyPath) is refused: the config.yaml of the level holds a template construct that a "
                + "write cannot keep. Edit the file by hand."
        case .invalidValue(let detail):
            "The settings after the change are not valid: \(detail). Correct the value."
        case .noLevel(let detail):
            "The level has no folder: \(detail)."
        case .unreadableSecret(let reference):
            "The secret store cannot tell if it has an item for the reference \"\(reference)\"."
        }
    }

    /// Gives the coded error of an error of the settings store.
    ///
    /// - Parameter error: The error that a store call threw.
    /// - Returns: The coded error of a known store error, or `error` with no
    ///   change. The toolkit gives each other error as `INTERNAL`.
    static func coded(_ error: any Error) -> any Error {
        switch error {
        case let error as SettingsTreeError:
            SettingsGraphError.invalidKeyPath(detail: error.description)
        case SettingsTemplateError.unkeptTemplate(let keyPath):
            SettingsGraphError.templateNotKept(keyPath: keyPath)
        case let error as ConfigurationError:
            SettingsGraphError.invalidValue(detail: error.description)
        case let error as YAMLValueDecodingError:
            SettingsGraphError.invalidValue(detail: error.description)
        case let error as SettingsStoreError:
            SettingsGraphError.noLevel(detail: error.description)
        default:
            error
        }
    }
}

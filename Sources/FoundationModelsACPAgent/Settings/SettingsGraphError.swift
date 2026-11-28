import Foundation
import FoundationModelsExtras

/// A settings call that the `settings` engine refuses (ACPA-17).
///
/// The `settings` endpoint and ``SettingsTool`` give each case in the
/// `errors` list of a response, with its ``code`` in `extensions.code`. The
/// ``message`` tells how to correct the call. No case holds a secret value:
/// a case names a key path or a reference only.
public enum SettingsGraphError: StoreCodedError, Equatable {
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

  /// `MISSING_CWD`: a change of the session level gives no working
  /// directory, and the endpoint has no session folder that applies in its
  /// place. A read and a user level change need no working directory.
  case missingWorkingDirectory

  /// `NOT_SESSION_CWD`: the call to the ``SettingsTool`` of a session gives
  /// a working directory that is not the folder of that session. The value
  /// is the path that the call gave.
  case otherSessionWorkingDirectory(path: String)

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

  /// `CHILD_RUN`: a child agent run tried to select a profile, or to
  /// clear the selected profile (D193). The profile is configuration of the
  /// user.
  case childRunProfile

  /// `NULL_VALUE`: an `updateSetting` call gave `null` as the value. A
  /// change removes a key with `clearSetting`, not with `null`. The value
  /// is the dotted key path of the change.
  case nullValue(keyPath: String)

  /// `NO_SESSION`: a call reads or sets the reasoning effort of a session
  /// (D218), and the call is not a call of the ``SettingsTool`` of a live
  /// session. A client sets the level with `session/set_config_option`.
  case noSessionReasoningEffort

  /// `UNKNOWN_EFFORT`: a `setReasoningEffort` call gave a level that is not
  /// a level of the model of the session (D218). `levels` is each level
  /// that the session can take, and is empty for a model with no levels.
  case unknownReasoningEffort(level: String, levels: [String])

  /// The code of the error, for example `UNKNOWN_SECTION`.
  public var code: String {
    switch self {
    case .unknownSection: "UNKNOWN_SECTION"
    case .invalidKeyPath: "INVALID_KEY_PATH"
    case .relativeWorkingDirectory: "INVALID_CWD"
    case .missingWorkingDirectory: "MISSING_CWD"
    case .otherSessionWorkingDirectory: "NOT_SESSION_CWD"
    case .secretNeedsReference: "SECRET_NEEDS_REFERENCE"
    case .templateNotKept: "TEMPLATE_NOT_KEPT"
    case .invalidValue: "INVALID_VALUE"
    case .noLevel: "NO_LEVEL"
    case .unreadableSecret: "SECRET_UNREADABLE"
    case .nullValue: "NULL_VALUE"
    case .noSessionReasoningEffort: "NO_SESSION"
    case .unknownReasoningEffort: "UNKNOWN_EFFORT"
    case .childRunProfile: ChildAgentRun.refusalCode
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
    case .missingWorkingDirectory:
      "A SESSION change needs a working directory, and the call gives none. Give the absolute path of the "
        + "session folder in cwd, or change the USER level."
    case .otherSessionWorkingDirectory(let path):
      "The working directory \"\(path)\" is not the folder of this session. Give no cwd: the folder of this "
        + "session applies."
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
    case .childRunProfile:
      ChildAgentRun.profileRefusal
    case .nullValue(let keyPath):
      "The value of \(keyPath) is null, and updateSetting does not take null. To remove the key from the "
        + "level, call clearSetting with the same keyPath and level."
    case .noSessionReasoningEffort:
      "The reasoning effort is a fact of a live session. Only the settings tool of that session reads and "
        + "sets it. A client sets it with session/set_config_option."
    case .unknownReasoningEffort(let level, let levels) where levels.isEmpty:
      "\"\(level)\" is not a reasoning effort level: the model of this session has no levels."
    case .unknownReasoningEffort(let level, let levels):
      "\"\(level)\" is not a reasoning effort level of the model of this session. Give one of these levels: "
        + "\(levels.joined(separator: ", "))."
    }
  }

  /// Gives the coded error of a known error of the settings store.
  ///
  /// - Parameter error: The error that a store call threw.
  /// - Returns: The coded error of a known store error, or `nil`.
  static func knownCode(of error: any Error) -> (any Error)? {
    switch error {
    case let error as SettingsTreeError:
      SettingsGraphError.invalidKeyPath(detail: error.description)
    case SettingsTemplateError.unkeptTemplate(let keyPath):
      SettingsGraphError.templateNotKept(keyPath: keyPath)
    case let error as ConfigurationError:
      SettingsGraphError.invalidValue(detail: error.description)
    case let error as YAMLValueDecodingError:
      SettingsGraphError.invalidValue(detail: error.description)
    case let error as ProfileStoreError:
      SettingsGraphError.invalidValue(detail: error.description)
    case let error as ProfileFileError:
      SettingsGraphError.invalidValue(detail: error.description)
    case let error as SettingsStoreError:
      SettingsGraphError.noLevel(detail: error.description)
    default:
      nil
    }
  }
}

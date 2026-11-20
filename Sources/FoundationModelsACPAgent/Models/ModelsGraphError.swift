import Foundation
import FoundationModelsExtras

/// A profile change that the `models` endpoint refuses.
///
/// The endpoint gives each case in the `errors` list of a response, with its
/// ``code`` in `extensions.code`. The ``message`` tells how to correct the
/// call.
public enum ModelsGraphError: StoreCodedError, Equatable {
  /// `READ_ONLY`: the call names the bundled layer, which no call changes.
  case readOnlyLayer

  /// `MISSING_CWD`: a change of the project layer gives no working
  /// directory.
  case missingWorkingDirectory

  /// `INVALID_CWD`: the working directory is not an absolute path. The value
  /// is the path that the call gave.
  case relativeWorkingDirectory(path: String)

  /// `INVALID_PROFILE`: the profile does not decode as a profile file. The
  /// detail is the reason of the decode.
  case invalidProfile(detail: String)

  /// `INVALID_NAME`: the name is not a plain file name.
  case invalidName(String)

  /// `NO_PROFILE_FILE`: the layer has no file of the profile.
  case noProfileFile(name: String)

  /// `NO_LEVEL`: the settings folders give no folder for the layer. The
  /// detail is the reason of the store.
  case noLevel(detail: String)

  /// `CHILD_RUN`: a child agent run tried to change a profile (D193).
  case childRun

  /// The code of the error, for example `READ_ONLY`.
  public var code: String {
    switch self {
    case .readOnlyLayer: "READ_ONLY"
    case .missingWorkingDirectory: "MISSING_CWD"
    case .relativeWorkingDirectory: "INVALID_CWD"
    case .invalidProfile: "INVALID_PROFILE"
    case .invalidName: "INVALID_NAME"
    case .noProfileFile: "NO_PROFILE_FILE"
    case .noLevel: "NO_LEVEL"
    case .childRun: ChildAgentRun.refusalCode
    }
  }

  /// The message of the error: what is wrong, and how to correct the call.
  public var message: String {
    switch self {
    case .readOnlyLayer:
      "The BUNDLED profiles are read-only. Save a profile of the same name to USER or PROJECT to override one."
    case .missingWorkingDirectory:
      "A PROJECT change needs a working directory, and the call gives none. Give the absolute path of the "
        + "project folder in cwd, or change the USER layer."
    case .relativeWorkingDirectory(let path):
      "The working directory \"\(path)\" is not an absolute path. Give the absolute path of the project folder."
    case .invalidProfile(let detail):
      "The profile is not valid: \(detail). Correct the profile."
    case .invalidName(let name):
      ProfileStoreError.invalidName(name).description + "."
    case .noProfileFile(let name):
      "The layer has no file of the profile \"\(name)\". Read the profiles to see the layer of each one."
    case .noLevel(let detail):
      "The layer has no folder: \(detail)."
    case .childRun:
      ChildAgentRun.profileRefusal
    }
  }

  /// Gives the coded error of a known error of the profile store.
  ///
  /// - Parameter error: The error that a store call threw.
  /// - Returns: The coded error of a known store error, or `nil`.
  static func knownCode(of error: any Error) -> (any Error)? {
    switch error {
    case let error as ProfileFileError:
      ModelsGraphError.invalidProfile(detail: error.description)
    case ProfileStoreError.invalidName(let name):
      ModelsGraphError.invalidName(name)
    case ProfileStoreError.noProfileFile(let name, _):
      ModelsGraphError.noProfileFile(name: name)
    case let error as ProfileStoreError:
      ModelsGraphError.noLevel(detail: error.description)
    default:
      nil
    }
  }
}

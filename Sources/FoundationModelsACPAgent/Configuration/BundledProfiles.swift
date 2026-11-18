import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The profiles that ship in the resources of the library:
/// `Resources/profiles/large.yaml`, `Resources/profiles/medium.yaml` and
/// `Resources/profiles/small.yaml`.
///
/// They are the lowest layer of the profiles, under the user layer and the
/// project layer (``ProfileStore``), and they are read-only. Each key that a
/// profile file leaves out takes its value from `large` (``baseName``,
/// ``ProfileFile``). The profile of a load where no layer sets `profile` is
/// the largest bundled profile that fits the machine
/// (``fallbackName(using:)``).
///
/// The files are part of the library, and the unit tests pin their contents,
/// thus a file that does not decode is a fault of the build and stops the
/// process.
public enum BundledProfiles {
  /// The name of the bundled profile whose file is the base of the merge of
  /// each profile file (``baseKeys``).
  static let baseName = "large"

  /// The name of the profile of a configuration that a caller makes in
  /// code (`ProfileConfiguration()`): `large`. A load where no layer sets
  /// `profile` does not use it: it uses the choice of
  /// ``fallbackName(using:)``.
  public static let defaultName = baseName

  /// The name of the smallest bundled profile. It is the choice of
  /// ``fallbackName(using:)`` when no fit can be read.
  public static let smallestName = "small"

  /// The name of the fallback profile: the profile that a load uses when
  /// no layer sets `profile`, and when the `profile` name of the settings
  /// names no profile of a layer.
  ///
  /// The choice is the first bundled profile, in the order of ``names``,
  /// whose fit says that it fits (decision D203). The fit includes the
  /// minimum context window of Router. When no fit can be read (there is
  /// no source, each estimate fails, or the task is cancelled), the choice
  /// is ``smallestName``.
  ///
  /// This is the one choice of the fallback. Each caller that needs the
  /// fallback calls this function: the agent, with its router, and the
  /// `acp-agent` CLI. The read of a fit is async and a load is not, thus a
  /// caller makes the choice before the load and gives the name to the
  /// loader (``ConfigurationLoader/fallbackProfileName``) or to the
  /// settings store (``SettingsStore/fallbackProfileName``).
  ///
  /// - Parameter source: The source of the fit of a profile, or `nil` when
  ///   no fit can be read.
  /// - Returns: The name of a bundled profile.
  public static func fallbackName(using source: (any ProfileFitEstimating)?) async -> String {
    guard let source else {
      return smallestName
    }
    for profile in all {
      let report = await source.fitReport(of: profile)
      if Task.isCancelled {
        return smallestName
      }
      if report.fits {
        return profile.name
      }
    }
    return smallestName
  }

  /// The memory of the Mac that each bundled profile is for, by name. The
  /// profile files do not hold it, because Router's profile has no such
  /// key; the description of each file names the same memory.
  private static let targetMemories = [
    baseName: "48 GB or more",
    mediumName: "32 GB",
    smallestName: "16 GB or 24 GB",
  ]

  /// The memory of the Mac that a bundled profile is for, such as
  /// "32 GB".
  ///
  /// - Parameter name: The name of the profile.
  /// - Returns: The memory, or `nil` when no bundled profile has the name.
  public static func targetMemory(of name: String) -> String? {
    targetMemories[name]
  }

  /// The names of the bundled profiles, from the largest to the smallest.
  /// A list shows the profiles in this order.
  static let names = [baseName, mediumName, smallestName]

  /// The name of the bundled profile between `large` and `small`.
  static let mediumName = "medium"

  /// The keys of the file of ``baseName``: the base of the merge of each
  /// profile file.
  static let baseKeys: [String: YAMLValue] = {
    guard case .dictionary(let keys) = tree(of: baseName) else {
      preconditionFailure("the bundled profile \(baseName) is not a mapping")
    }
    return keys
  }()

  /// The bundled profiles, in the order of ``names``.
  public static let all: [ProfileDefinition] = names.map { name in
    do {
      return try ProfileFile.definition(of: tree(of: name), name: name, path: path(of: name))
    } catch {
      preconditionFailure("the bundled profile \(name) does not decode: \(error)")
    }
  }

  /// The profile of ``defaultName``, `large`.
  public static var defaultProfile: ProfileDefinition {
    guard let profile = named(defaultName) else {
      preconditionFailure("the bundled profiles have no profile named \(defaultName)")
    }
    return profile
  }

  /// The bundled profile that has a name.
  ///
  /// - Parameter name: The name.
  /// - Returns: The profile, or `nil` when no bundled profile has the name.
  public static func named(_ name: String) -> ProfileDefinition? {
    all.first { $0.name == name }
  }

  /// The location of a bundled profile file in the resource bundle.
  ///
  /// - Parameter name: The name of the profile.
  /// - Returns: The file URL, or `nil` when the bundle has no such file.
  static func url(of name: String) -> URL? {
    Bundle.module.url(
      forResource: name, withExtension: ProfileFile.fileExtension,
      subdirectory: ProfileFile.folderName)
  }

  /// The path of a bundled profile file, for the errors.
  ///
  /// - Parameter name: The name of the profile.
  /// - Returns: The path, or the bare file name when the bundle has no file.
  static func path(of name: String) -> String {
    url(of: name)?.path ?? "\(name).\(ProfileFile.fileExtension)"
  }

  /// The parsed tree of a bundled profile file.
  ///
  /// - Parameter name: The name of the profile.
  /// - Returns: The tree.
  private static func tree(of name: String) -> YAMLValue {
    guard let url = url(of: name), let text = try? String(contentsOf: url, encoding: .utf8),
      let tree = try? YAMLValue.parse(text)
    else {
      preconditionFailure("the bundled profile \(name) cannot be read")
    }
    return tree
  }
}

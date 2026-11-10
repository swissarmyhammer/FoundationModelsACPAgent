import Foundation
import FoundationModelsACPAgent

/// The one maker of the ``AgentHome`` of a test: a custom home over
/// throwaway folders, so no test reads or writes a folder of the real home
/// directory.
public enum AgentHomeFixture {
  /// The folder of the project store in the synced root when the test
  /// gives no projects folder of its own.
  public static let projectsFolderName = "projects"

  /// Makes a custom home with a new throwaway local root.
  ///
  /// - Parameters:
  ///   - label: The directory label, so a leftover directory says where it
  ///     came from.
  ///   - synced: The synced root, or `nil` (the default) for a new
  ///     throwaway folder. A suite that writes into the user layer gives its
  ///     own folder here.
  ///   - projects: The projects folder, or `nil` (the default) for the
  ///     ``projectsFolderName`` folder of the synced root. A suite that
  ///     puts the project store outside the synced root gives its own
  ///     folder here.
  /// - Returns: The home.
  public static func make(label: String, synced: URL? = nil, projects: URL? = nil) -> AgentHome {
    let synced = synced ?? makeResolvedDirectory(label: "\(label)-synced")
    return .makeCustom(
      synced: synced,
      local: makeResolvedDirectory(label: "\(label)-local"),
      projects: projects
        ?? synced.appendingPathComponent(projectsFolderName, isDirectory: true))
  }
}

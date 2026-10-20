import Foundation
import FoundationModelsACPAgent

/// The one maker of the ``SettingsFolders`` of a test over a throwaway root
/// settings folder. Each suite that makes a `CatalogContext` or a
/// `SettingsStore` itself calls it, so no such object reads a folder in the
/// real home directory.
public enum SettingsFoldersFixture {
    /// The dotfolder name of the configuration of the settings folders. A
    /// catalog context reads only the skills and agents stacks, which do not
    /// read this name. A settings store reads the session level of a working
    /// directory in `<cwd>/.<this name>/`.
    static let dotfolderName = "catalog-test"

    /// Makes settings folders over a new throwaway root settings folder.
    ///
    /// - Parameters:
    ///   - label: The directory label, so a leftover directory says where it
    ///     came from.
    ///   - environment: The environment that the stacks read their defaults
    ///     layer from. Empty by default.
    /// - Returns: The settings folders.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
    public static func make(label: String, environment: [String: String] = [:]) throws -> SettingsFolders {
        SettingsFolders(
            name: try DotfolderName(dotfolderName),
            rootSettingsFolder: makeResolvedDirectory(label: "\(label)-settings"),
            environment: environment)
    }
}

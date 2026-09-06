import Foundation
import FoundationModelsACPAgent

/// The one writer of a layer's `config.yaml` in a test tree (plan.md
/// §20.1). Every fixture that seeds a user or project layer calls it, so
/// the file is written the same way in each suite, and the nested
/// `IntegrationTests` package reaches it as a product.
public enum ConfigFileFixture {
    /// Writes `yaml` as `config.yaml` inside `directory`, and creates the
    /// directory first.
    ///
    /// - Parameters:
    ///   - yaml: The file content.
    ///   - directory: The layer root the file goes in.
    /// - Throws: The directory-creation or write error.
    public static func write(_ yaml: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try yaml.write(
            to: directory.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
    }
}

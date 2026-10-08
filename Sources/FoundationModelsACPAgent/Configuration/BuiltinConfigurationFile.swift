import Foundation
import FoundationModelsExtras

/// A failure to read the builtin configuration file, layer 1 of the
/// configuration stack. `ConfigurationLoader.load()` throws it.
public enum BuiltinConfigurationFileError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The resource bundle of the library has no builtin configuration file.
    case missing(fileName: String)

    /// The file cannot be read as UTF-8 text. `reason` is the description of
    /// the error that the file system gives, thus the caller learns the real
    /// cause, for example a missing permission or an I/O error.
    case unreadable(path: String, reason: String)

    /// A human-readable reason that names the file.
    public var description: String {
        switch self {
        case .missing(let fileName):
            return "the resource bundle has no builtin configuration file \(fileName)"
        case .unreadable(let path, let reason):
            return "the builtin configuration file \(path) cannot be read as UTF-8 text: \(reason)"
        }
    }
}

/// The builtin configuration file `builtin.config.yaml`: layer 1 of the
/// configuration stack (plan.md §2.2), a resource of the library target.
///
/// The file names each tool under `tools:` with its default options, thus a
/// person can read which tools exist and which are on. ``ConfigurationLoader``
/// reads it under the user layer and the project layer. The property defaults
/// of ``AgentConfiguration`` stay as the decode fallback for a key that no
/// layer sets, and the unit tests make sure that the file decodes to exactly
/// `AgentConfiguration()`.
///
/// The file holds no secret: the map of web API keys is empty.
enum BuiltinConfigurationFile {
    /// The name of the file, without its extension.
    static let resourceName = "builtin.config"

    /// The extension of the file.
    static let resourceExtension = "yaml"

    /// The name of the file in the resource bundle.
    static var fileName: String {
        "\(resourceName).\(resourceExtension)"
    }

    /// The location of the file in the resource bundle of the library.
    ///
    /// - Returns: The file URL.
    /// - Throws: ``BuiltinConfigurationFileError/missing(fileName:)`` when
    ///   the bundle has no such file.
    static func url() throws -> URL {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension)
        else {
            throw BuiltinConfigurationFileError.missing(fileName: fileName)
        }
        return url
    }

    /// The parsed tree of the file.
    ///
    /// - Returns: The tree, layer 1 of the configuration stack.
    /// - Throws: ``BuiltinConfigurationFileError`` when the file is missing or
    ///   cannot be read; `YAMLValueParsingError` when its text is not YAML.
    static func root() throws -> YAMLValue {
        try root(at: url())
    }

    /// The parsed tree of the configuration file at `url`.
    ///
    /// - Parameter url: The location of the file.
    /// - Returns: The tree.
    /// - Throws: ``BuiltinConfigurationFileError/unreadable(path:reason:)``
    ///   with the reason of the file system when the file cannot be read as
    ///   UTF-8 text; `YAMLValueParsingError` when its text is not YAML.
    static func root(at url: URL) throws -> YAMLValue {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BuiltinConfigurationFileError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        return try YAMLValue.parse(text)
    }
}

extension YAMLValue {
    /// This tree as the lowest layer, with `higher` merged over it by the
    /// one layered-merge rule of the family: two mappings merge by key, and
    /// each other value of `higher` replaces this value.
    ///
    /// `LayeredYAMLDocument` merges the dotfolder layers by the same rule,
    /// but its merge is not public, thus the loader puts the builtin layer
    /// under the merged dotfolder tree with this function.
    ///
    /// - Parameter higher: The tree of the higher layers.
    /// - Returns: The merged tree.
    func layered(under higher: YAMLValue) -> YAMLValue {
        guard case .dictionary(let lowerKeys) = self, case .dictionary(let higherKeys) = higher else {
            return higher
        }
        return .dictionary(
            lowerKeys.merging(higherKeys) { lowerValue, higherValue in
                lowerValue.layered(under: higherValue)
            })
    }
}

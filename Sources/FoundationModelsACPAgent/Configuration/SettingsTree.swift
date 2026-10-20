import Foundation
import FoundationModelsExtras

/// A change to a settings tree that the tree cannot take.
public enum SettingsTreeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The key path has no key.
    case emptyKeyPath

    /// A key on the way to the changed key holds a scalar or a list, thus it
    /// cannot hold a child key. `keyPath` is the dotted key path of that key.
    case notAMapping(keyPath: String)

    /// A human-readable reason that names the key path.
    public var description: String {
        switch self {
        case .emptyKeyPath:
            return "\(ConfigurationLoader.configFileName): a settings change must name a key"
        case .notAMapping(let keyPath):
            return
                "\(ConfigurationLoader.configFileName): the key \"\(keyPath)\" holds a value that is not a mapping, thus it cannot hold a child key"
        }
    }
}

extension YAMLValue {
    /// This tree as a `JSONSerialization` value: a `String`, an `NSNumber`
    /// (a boolean, an integer or a double), `NSNull`, an array or a mapping.
    /// ``ConfigurationYAML`` emits this shape.
    var serializationValue: Any {
        switch self {
        case .string(let text):
            return text
        case .int(let number):
            return NSNumber(value: number)
        case .double(let number):
            return NSNumber(value: number)
        case .bool(let flag):
            return NSNumber(value: flag)
        case .null:
            return NSNull()
        case .array(let items):
            return items.map(\.serializationValue)
        case .dictionary(let keys):
            return keys.mapValues(\.serializationValue)
        }
    }

    /// The value at `keyPath` in this tree.
    ///
    /// - Parameter keyPath: The keys from the root, such as
    ///   `["compaction", "trigger"]`. An empty key path names the root.
    /// - Returns: The value, or `nil` when a key of the path is not there.
    func value(at keyPath: [String]) -> YAMLValue? {
        guard let key = keyPath.first else {
            return self
        }
        guard case .dictionary(let keys) = self, let child = keys[key] else {
            return nil
        }
        return child.value(at: Array(keyPath.dropFirst()))
    }

    /// This tree with `value` at `keyPath`. Each mapping on the way that is
    /// not there is made. A `null` on the way acts as an empty mapping.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - keyPath: The keys from the root. It must name a key.
    /// - Returns: The changed tree.
    /// - Throws: ``SettingsTreeError/emptyKeyPath`` for an empty key path;
    ///   ``SettingsTreeError/notAMapping(keyPath:)`` when a key on the way
    ///   holds a scalar or a list.
    func setting(_ value: YAMLValue, at keyPath: [String]) throws -> YAMLValue {
        guard !keyPath.isEmpty else {
            throw SettingsTreeError.emptyKeyPath
        }
        return try setting(value, at: keyPath[...], under: [])
    }

    /// This tree without the key at `keyPath`. A key that is not there
    /// changes nothing. A mapping that the removal makes empty stays, as an
    /// empty mapping merges with no effect.
    ///
    /// - Parameter keyPath: The keys from the root. It must name a key.
    /// - Returns: The changed tree.
    /// - Throws: ``SettingsTreeError/emptyKeyPath`` for an empty key path.
    func removingValue(at keyPath: [String]) throws -> YAMLValue {
        guard let key = keyPath.first else {
            throw SettingsTreeError.emptyKeyPath
        }
        guard case .dictionary(var keys) = self, let child = keys[key] else {
            return self
        }
        let rest = Array(keyPath.dropFirst())
        keys[key] = rest.isEmpty ? nil : try child.removingValue(at: rest)
        return .dictionary(keys)
    }

    /// This tree with `value` at `keyPath`, below the keys of `parent`.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - keyPath: The keys from this tree. It is not empty.
    ///   - parent: The keys from the root to this tree, for the error.
    /// - Returns: The changed tree.
    /// - Throws: ``SettingsTreeError/notAMapping(keyPath:)`` when this tree
    ///   is a scalar or a list.
    private func setting(_ value: YAMLValue, at keyPath: ArraySlice<String>, under parent: [String])
        throws -> YAMLValue
    {
        guard let key = keyPath.first else {
            return value
        }
        var keys: [String: YAMLValue]
        switch self {
        case .null:
            keys = [:]
        case .dictionary(let children):
            keys = children
        case .string, .int, .double, .bool, .array:
            throw SettingsTreeError.notAMapping(
                keyPath: parent.joined(separator: LoadedConfiguration.keyPathSeparator))
        }
        keys[key] = try (keys[key] ?? .null).setting(value, at: keyPath.dropFirst(), under: parent + [key])
        return .dictionary(keys)
    }
}

/// The merged tree of the settings levels in memory, and the level that set
/// each key path.
///
/// The merge rule and the source of each key are the rule and the sources of
/// `LayeredYAMLDocument`: two mappings merge by key, and each other value of
/// a higher level replaces the lower value. A key gets the source of the
/// level that put it in the tree. A mapping key that a higher level merges
/// into keeps the source of the level that put it in first.
/// `LayeredYAMLDocument` merges only the files of a stack, and its merge is
/// not public, thus ``SettingsStore`` merges its trees with this type.
struct MergedSettings {
    /// The tree of one level and the source of its layer. A level whose tree
    /// is `.null` (no file, or an empty file) sets no key.
    typealias LevelTree = (source: DotfolderStack.Source, root: YAMLValue)

    /// The merged tree, or `.null` when no level sets a key.
    let root: YAMLValue

    /// The level that set each key path of ``root``.
    private let sourcesByKeyPath: [[String]: DotfolderStack.Source]

    /// Merges `levels`, lowest precedence first.
    ///
    /// - Parameter levels: The tree of each level and its source.
    init(levels: [LevelTree]) {
        var sources: [[String]: DotfolderStack.Source] = [:]
        var merged = YAMLValue.null
        for level in levels where level.root != .null {
            merged = Self.merge(
                lower: merged, higher: level.root, source: level.source, keyPath: [], into: &sources)
        }
        root = merged
        sourcesByKeyPath = sources
    }

    /// The level that set `keyPath`.
    ///
    /// - Parameter keyPath: The keys from the root.
    /// - Returns: The source of the level, or `nil` when no level set it.
    func source(of keyPath: [String]) -> DotfolderStack.Source? {
        sourcesByKeyPath[keyPath]
    }

    /// The level that set each key of ``root``, by dotted key path, as
    /// ``LoadedConfiguration/sources`` gives it.
    var dottedSources: [String: DotfolderStack.Source] {
        ConfigurationLoader.sources(in: root, sourceOf: source(of:))
    }

    /// Merges `higher` over `lower` and records the source of each key that
    /// `higher` puts in the tree.
    ///
    /// - Parameters:
    ///   - lower: The merged tree of the lower levels, or `.null`.
    ///   - higher: The tree of the higher level.
    ///   - source: The source of the higher level.
    ///   - keyPath: The key path of both trees.
    ///   - sources: The source of each key path. The merge adds to it.
    /// - Returns: The merged tree.
    private static func merge(
        lower: YAMLValue, higher: YAMLValue, source: DotfolderStack.Source, keyPath: [String],
        into sources: inout [[String]: DotfolderStack.Source]
    ) -> YAMLValue {
        guard case .dictionary(let lowerKeys) = lower, case .dictionary(let higherKeys) = higher else {
            record(higher, source: source, keyPath: keyPath, into: &sources)
            return higher
        }
        var merged = lowerKeys
        for (key, higherValue) in higherKeys {
            let childKeyPath = keyPath + [key]
            guard let lowerValue = lowerKeys[key] else {
                merged[key] = higherValue
                record(higherValue, source: source, keyPath: childKeyPath, into: &sources)
                continue
            }
            merged[key] = merge(
                lower: lowerValue, higher: higherValue, source: source, keyPath: childKeyPath,
                into: &sources)
        }
        return .dictionary(merged)
    }

    /// Records `source` for `keyPath` and for each key path below it in
    /// `value`.
    ///
    /// - Parameters:
    ///   - value: The tree that the level put in.
    ///   - source: The source of the level.
    ///   - keyPath: The key path of `value`.
    ///   - sources: The source of each key path. The record adds to it.
    private static func record(
        _ value: YAMLValue, source: DotfolderStack.Source, keyPath: [String],
        into sources: inout [[String]: DotfolderStack.Source]
    ) {
        sources[keyPath] = source
        guard case .dictionary(let keys) = value else {
            return
        }
        for (key, child) in keys {
            record(child, source: source, keyPath: keyPath + [key], into: &sources)
        }
    }
}

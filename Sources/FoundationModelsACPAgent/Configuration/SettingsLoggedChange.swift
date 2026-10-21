import Foundation
import FoundationModelsExtras

/// One change in the change log of a ``SettingsStore`` (EXTRAS-9 rule 9): the
/// change, and the dotted key path of each key that it added, changed and
/// removed.
///
/// The ids follow the change:
///
/// - A `set` of a key that had no value on its level adds the key path; a
///   `set` of a key that had a value changes it.
/// - A `clear` removes the key path.
/// - A change of the file of a level from outside, and the read of a level
///   again after ``SettingsStore/stopWatching()``, have no key path
///   (``SettingsChange/keyPath`` is `nil`). Their ids are the leaf key paths
///   whose value differs between the tree before and the tree after
///   (``SettingsTreeDifference``). A read again after a stop with no
///   difference has no id: the change then only tells that the store read
///   the level again.
///
/// A change holds no value, because a value can be a secret.
public struct SettingsLoggedChange: Sendable {
    /// The change: its level and its key path.
    public let change: SettingsChange

    /// The dotted key paths that the change added, changed and removed.
    public let ids: ChangedIDs

    /// Makes a logged change.
    ///
    /// - Parameters:
    ///   - change: The change.
    ///   - ids: The dotted key paths that the change added, changed and
    ///     removed.
    public init(change: SettingsChange, ids: ChangedIDs) {
        self.change = change
        self.ids = ids
    }
}

/// The difference between two trees of one settings level, as the dotted key
/// path of each leaf key that one tree adds, changes or removes.
///
/// Two mappings differ key by key, down to the leaves, and a mapping that one
/// tree adds or removes as a whole gives each of its leaves. A value that is
/// not a mapping (a scalar, a list or an empty mapping) is one leaf: a list
/// that differs in one item changes the key of the list. A root that is not a
/// mapping, for example the `null` root of a level with no file, has no key.
enum SettingsTreeDifference {
    /// The text between two keys of a dotted key path.
    static let separator = "."

    /// The kind of one difference.
    private enum Kind {
        /// The key is in the tree after only.
        case added

        /// The key is in both trees with a different value.
        case changed

        /// The key is in the tree before only.
        case removed
    }

    /// Gives the dotted form of a key path, as an id of a change.
    ///
    /// - Parameter keyPath: The keys from the root.
    /// - Returns: The keys joined with ``separator``.
    static func id(of keyPath: [String]) -> String {
        keyPath.joined(separator: separator)
    }

    /// Gives the key paths that differ between two trees of a level.
    ///
    /// - Parameters:
    ///   - old: The tree before the change.
    ///   - new: The tree after the change.
    /// - Returns: The dotted key path of each leaf key that `new` adds,
    ///   changes or removes, each list in the sorted order of the keys.
    static func ids(from old: YAMLValue, to new: YAMLValue) -> ChangedIDs {
        let differences = differences(from: rootMapping(of: old), to: rootMapping(of: new), at: [])
        return ChangedIDs(
            added: differences.filter { $0.kind == .added }.map(\.id),
            changed: differences.filter { $0.kind == .changed }.map(\.id),
            removed: differences.filter { $0.kind == .removed }.map(\.id))
    }

    /// Gives the root of a tree as a mapping.
    ///
    /// - Parameter root: The root of a tree.
    /// - Returns: The root, or an empty mapping when the root is not a
    ///   mapping.
    private static func rootMapping(of root: YAMLValue) -> YAMLValue {
        guard case .dictionary = root else {
            return .dictionary([:])
        }
        return root
    }

    /// Gives the differences of two values at one key path.
    ///
    /// - Parameters:
    ///   - old: The value before, or `nil` when the key was not there.
    ///   - new: The value after, or `nil` when the key is not there.
    ///   - keyPath: The key path of the values.
    /// - Returns: Each difference, in the sorted order of the keys.
    private static func differences(
        from old: YAMLValue?, to new: YAMLValue?, at keyPath: [String]
    ) -> [(kind: Kind, id: String)] {
        if let (oldKeys, newKeys) = mappings(of: old, and: new) {
            return Set(oldKeys.keys).union(newKeys.keys).sorted().flatMap { key in
                differences(from: oldKeys[key], to: newKeys[key], at: keyPath + [key])
            }
        }
        guard old != new else {
            return []
        }
        let kind: Kind =
            switch (old, new) {
            case (nil, _): .added
            case (_, nil): .removed
            default: .changed
            }
        return [(kind: kind, id: id(of: keyPath))]
    }

    /// Gives the keys of two values that differ key by key: two mappings, or
    /// a mapping with keys on one side and no value on the other side, which
    /// then has no key.
    ///
    /// - Parameters:
    ///   - old: The value before, or `nil` when the key was not there.
    ///   - new: The value after, or `nil` when the key is not there.
    /// - Returns: The keys of each side, or `nil` when the two values are
    ///   leaves.
    private static func mappings(
        of old: YAMLValue?, and new: YAMLValue?
    ) -> (old: [String: YAMLValue], new: [String: YAMLValue])? {
        switch (old, new) {
        case (.dictionary(let oldKeys)?, .dictionary(let newKeys)?):
            (old: oldKeys, new: newKeys)
        case (nil, .dictionary(let newKeys)?) where !newKeys.isEmpty:
            (old: [:], new: newKeys)
        case (.dictionary(let oldKeys)?, nil) where !oldKeys.isEmpty:
            (old: oldKeys, new: [:])
        default:
            nil
        }
    }
}

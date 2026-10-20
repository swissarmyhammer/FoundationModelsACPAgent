import Foundation
import FoundationModelsExtras

/// The keys of the configuration whose value is a secret, and the rules of
/// the `settings` engine for them (ACPA-17, ACPA-18, D101).
///
/// A secret key holds only a `keychain:<name>` reference
/// (``ConfiguredSecret/referencePrefix``). The value of the reference stays
/// in the ``SecretStore`` of the agent. Thus no value goes through the
/// `settings` endpoint or ``SettingsTool``: a change that gives a literal
/// value for a secret key is refused, and a read shows a literal that a file
/// holds as ``ConfiguredSecret/redactedForm``.
///
/// The secret keys are each key of `tools.web.apiKeys` and each key of the
/// `headers` of each MCP server in the `tools.mcp` list. An `env` value of an
/// MCP server is not a secret key: an `env` value is often not a secret, for
/// example `PATH`, thus the codec keeps a literal `env` value too
/// (``MCPServerConfiguration``).
enum SettingsSecretKeys {
    /// One secret key inside a settings value.
    struct Slot: Equatable, Sendable {
        /// The dotted key path of the secret key from the root. The name of
        /// an MCP server stands in place of its index in the `tools.mcp`
        /// list, the same as in a configuration warning.
        let keyPath: String

        /// The value of the secret key.
        let value: YAMLValue

        /// The reference name of ``value``: the `<name>` part of
        /// `keychain:<name>`, or `nil` when the value is not a reference.
        var referenceName: String? {
            SettingsSecretKeys.referenceName(of: value)
        }
    }

    /// One step of the path of a secret key from the root.
    private enum Step {
        /// The key with this name.
        case key(String)

        /// Each key of a mapping.
        case anyKey

        /// Each item of a list.
        case anyItem
    }

    /// The paths of the secret keys from the root.
    private static let paths: [[Step]] = [
        [
            .key(AgentConfiguration.CodingKeys.tools.stringValue),
            .key(ToolsConfiguration.CodingKeys.web.stringValue),
            .key(WebToolOptions.CodingKeys.apiKeys.stringValue),
            .anyKey,
        ],
        [
            .key(AgentConfiguration.CodingKeys.tools.stringValue),
            .key(ToolsConfiguration.CodingKeys.mcp.stringValue),
            .anyItem,
            .key(MCPServerConfiguration.CodingKeys.headers.stringValue),
            .anyKey,
        ],
    ]

    /// The key of an MCP server entry that names the server.
    private static let serverNameKey = MCPServerConfiguration.CodingKeys.name.stringValue

    // MARK: - Reads

    /// Gives each secret key inside a value.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - keyPath: The key path of `value` from the root.
    /// - Returns: The secret keys, in the order of the paths and then of the
    ///   sorted keys and the list items.
    static func slots(in value: YAMLValue, at keyPath: [String]) -> [Slot] {
        var slots: [Slot] = []
        _ = mapping(value, at: keyPath) { slot in
            slots.append(slot)
            return slot.value
        }
        return slots
    }

    /// Gives a value with each secret key that is not a reference replaced by
    /// ``ConfiguredSecret/redactedForm``. A reference and a `null` stay.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - keyPath: The key path of `value` from the root.
    /// - Returns: The value that a read can show.
    static func redacted(_ value: YAMLValue, at keyPath: [String]) -> YAMLValue {
        mapping(value, at: keyPath) { slot in
            slot.referenceName != nil || slot.value == .null ? slot.value : .string(ConfiguredSecret.redactedForm)
        }
    }

    /// Checks that each secret key inside a value is a `keychain:<name>`
    /// reference.
    ///
    /// - Parameters:
    ///   - value: The value that a change writes.
    ///   - keyPath: The key path of `value` from the root.
    /// - Throws: ``SettingsGraphError/secretNeedsReference(keyPath:)`` for the
    ///   first secret key that is not a reference. The error names the key,
    ///   and not the value.
    static func requireReferences(in value: YAMLValue, at keyPath: [String]) throws {
        let literal = slots(in: value, at: keyPath).first { slot in slot.referenceName == nil }
        if let literal {
            throw SettingsGraphError.secretNeedsReference(keyPath: literal.keyPath)
        }
    }

    /// Gives the reference name of a value.
    ///
    /// - Parameter value: The value of a secret key.
    /// - Returns: The `<name>` part of `keychain:<name>`, or `nil` when the
    ///   value is not a string with the prefix and a name.
    static func referenceName(of value: YAMLValue) -> String? {
        guard case .string(let text) = value, text.hasPrefix(ConfiguredSecret.referencePrefix) else {
            return nil
        }
        let name = String(text.dropFirst(ConfiguredSecret.referencePrefix.count))
        return name.isEmpty ? nil : name
    }

    // MARK: - The walk

    /// Gives a value with each secret key inside it changed by `transform`.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - keyPath: The key path of `value` from the root.
    ///   - transform: Gives the new value of one secret key.
    /// - Returns: The changed value.
    /// - Throws: What `transform` throws.
    private static func mapping(
        _ value: YAMLValue, at keyPath: [String], _ transform: (Slot) throws -> YAMLValue
    ) rethrows -> YAMLValue {
        try paths.reduce(value) { changed, path in
            guard let rest = remainder(of: path, after: keyPath) else {
                return changed
            }
            return try walk(changed, steps: rest[...], dotted: keyPath, transform)
        }
    }

    /// Gives the steps of a path that come after a key path.
    ///
    /// - Parameters:
    ///   - path: The path of a secret key.
    ///   - keyPath: The key path of a value.
    /// - Returns: The steps after `keyPath`, or `nil` when `keyPath` is not on
    ///   the path. A key path goes through mappings only, thus it is not on a
    ///   path where the path goes into a list item.
    private static func remainder(of path: [Step], after keyPath: [String]) -> [Step]? {
        guard keyPath.count <= path.count else {
            return nil
        }
        let matches = zip(path, keyPath).allSatisfy { step, key in
            switch step {
            case .key(let name):
                name == key
            case .anyKey:
                true
            case .anyItem:
                false
            }
        }
        return matches ? Array(path.dropFirst(keyPath.count)) : nil
    }

    /// Changes each secret key below one value.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - steps: The steps of the path from `value` to a secret key.
    ///   - dotted: The keys from the root to `value`, for the key path of a
    ///     slot.
    ///   - transform: Gives the new value of one secret key.
    /// - Returns: The changed value.
    /// - Throws: What `transform` throws.
    private static func walk(
        _ value: YAMLValue, steps: ArraySlice<Step>, dotted: [String], _ transform: (Slot) throws -> YAMLValue
    ) rethrows -> YAMLValue {
        guard let step = steps.first else {
            return try transform(
                Slot(keyPath: dotted.joined(separator: LoadedConfiguration.keyPathSeparator), value: value))
        }
        let rest = steps.dropFirst()
        switch (step, value) {
        case (.key(let name), .dictionary(var keys)):
            guard let child = keys[name] else {
                return value
            }
            keys[name] = try walk(child, steps: rest, dotted: dotted + [name], transform)
            return .dictionary(keys)
        case (.anyKey, .dictionary(let keys)):
            return .dictionary(
                try keys.mapValuesWithKeys { key, child in
                    try walk(child, steps: rest, dotted: dotted + [key], transform)
                })
        case (.anyItem, .array(let items)):
            return .array(
                try items.enumerated().map { index, item in
                    try walk(item, steps: rest, dotted: dotted + [itemName(of: item, at: index)], transform)
                })
        default:
            return value
        }
    }

    /// Gives the name of one item of the `tools.mcp` list for a key path.
    ///
    /// - Parameters:
    ///   - item: The item.
    ///   - index: The index of the item in the list.
    /// - Returns: The `name` of the server, or the index when the item has no
    ///   name.
    private static func itemName(of item: YAMLValue, at index: Int) -> String {
        guard case .dictionary(let keys) = item, case .string(let name)? = keys[serverNameKey] else {
            return String(index)
        }
        return name
    }
}

extension Dictionary where Key == String {
    /// Gives this dictionary with each value changed by a function that also
    /// reads the key. The function gets the keys in sorted order, thus a
    /// function with a side effect sees the same order each time.
    ///
    /// - Parameter transform: Gives the new value of one key.
    /// - Returns: The changed dictionary.
    /// - Throws: What `transform` throws.
    fileprivate func mapValuesWithKeys<NewValue>(
        _ transform: (String, Value) throws -> NewValue
    ) rethrows -> [String: NewValue] {
        Dictionary<String, NewValue>(
            uniqueKeysWithValues: try sorted { $0.key < $1.key }.map { key, value in
                (key, try transform(key, value))
            })
    }
}

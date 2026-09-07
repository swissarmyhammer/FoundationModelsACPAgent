import Foundation
import FoundationModelsExtras

/// Emits an ``AgentConfiguration`` as commented block YAML (plan.md §14.1,
/// §2.2, cli-plan.md §5.11).
///
/// **This is the one generator, and it has four callers.** The `/config`
/// builtin prints the text; `/config export` writes it to a layer's
/// `config.yaml` — the §2.2 eject counterpart; `config show` prints it,
/// with the layer of each key under `--source`; and `config init` writes
/// the defaults of a fresh `config.yaml` with it. Two front doors write
/// the same file, so they must write the same bytes, and one generator is
/// how they cannot drift.
///
/// The text round-trips through ``ConfigurationLoader``: it names only
/// schema keys, and it names every one of them, so the loader reads it
/// back to the same configuration.
///
/// The value tree comes from the configuration's own `Codable` encoding, so
/// the per-tool codecs (a disabled tool as `false`, the `mcp:` server list, a
/// transcript location word) each serialize exactly as the loader decodes
/// them. Every string scalar is emitted double-quoted, so a value that
/// carries YAML punctuation stays one scalar.
public enum ConfigurationYAML {
    /// A shape the emitter cannot serialize.
    public enum EmitError: Error, Equatable {
        /// The encoded configuration was not a mapping of sections.
        case notAMapping
    }

    /// What each key line carries after its value.
    public enum KeyAnnotation: Equatable, Sendable {
        /// Nothing: the plain document `/config` prints.
        case none

        /// A trailing comment that names the layer that set the key
        /// (cli-plan.md §5.11), from the loader's per-key source map. A
        /// key with no entry names `builtin`.
        case sources([String: DotfolderStack.Source])
    }

    /// One emitted line: its text, and the dotted key path of the key it
    /// declares. A comment, a sequence item, and a key inside a sequence
    /// item declare no key path: a sequence replaces wholesale across
    /// layers, so its own key carries the whole item.
    private struct Line {
        /// The line, indented, without a newline.
        let text: String

        /// The dotted key path, or `nil` when the line declares no key.
        let keyPath: String?
    }

    /// The number of spaces one indentation level adds.
    private static let indentWidth = 2

    /// The text between a key line and its layer annotation.
    private static let annotationPrefix = "  # "

    /// The Objective-C type encoding of a double-precision float.
    private static let objCDoubleType = "d"

    /// The Objective-C type encoding of a single-precision float.
    private static let objCFloatType = "f"

    /// The top-level sections, in the order the document emits them.
    private static let sectionOrder = ["profile", "tools", "recording", "transcripts", "compaction", "sandbox"]

    /// The comment printed above each top-level section.
    private static let sectionComments: [String: String] = [
        "profile": "The model profile: the standard, flash and embedding slots.",
        "tools": "The tool roster: each capability is on unless set to false.",
        "recording": "How much of each session is recorded: full or off.",
        "transcripts": "Where transcripts are written: project, home or an absolute path.",
        "compaction": "The token-budget thresholds of the self-folding session.",
        "sandbox": "Extra write grants beyond the session root set.",
    ]

    /// The comment printed at the top of the document.
    private static let headerComment =
        "# The effective configuration (plan.md §2.2). Edit and reload, or eject with /config export."

    /// Renders `configuration` as commented block YAML.
    ///
    /// - Parameters:
    ///   - configuration: The configuration to render.
    ///   - annotation: What each key line carries after its value.
    /// - Returns: The YAML document, newline-terminated.
    /// - Throws: ``EmitError/notAMapping`` when the encoded configuration is
    ///   not a mapping, or a `JSONEncoder`/`JSONSerialization` error.
    public static func documentText(
        for configuration: AgentConfiguration, annotation: KeyAnnotation = .none
    ) throws -> String {
        try lines(of: configuration)
            .map { annotated($0, with: annotation) }
            .joined(separator: "\n") + "\n"
    }

    /// Every key path of `configuration`'s tree, dotted, in the order the
    /// document emits them. A key inside a sequence item is not listed —
    /// see ``Line``.
    ///
    /// - Parameter configuration: The configuration to walk.
    /// - Returns: The dotted key paths.
    /// - Throws: What ``documentText(for:annotation:)`` throws.
    public static func keyPaths(of configuration: AgentConfiguration) throws -> [String] {
        try lines(of: configuration).compactMap(\.keyPath)
    }

    /// The text of `line` with `annotation` applied: the layer comment
    /// after a key line, and the text alone otherwise.
    private static func annotated(_ line: Line, with annotation: KeyAnnotation) -> String {
        switch annotation {
        case .none:
            return line.text
        case .sources(let sources):
            guard let keyPath = line.keyPath else {
                return line.text
            }
            return line.text + annotationPrefix + ConfigurationLayerName(sources[keyPath]).rawValue
        }
    }

    /// The lines of the document: the header, then each section under its
    /// comment.
    ///
    /// - Parameter configuration: The configuration to render.
    /// - Returns: The lines, in document order.
    /// - Throws: ``EmitError/notAMapping`` when the encoded configuration is
    ///   not a mapping, or a `JSONEncoder`/`JSONSerialization` error.
    private static func lines(of configuration: AgentConfiguration) throws -> [Line] {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
        guard let sections = encoded as? [String: Any] else {
            throw EmitError.notAMapping
        }
        return [Line(text: headerComment, keyPath: nil)]
            + sectionOrder.flatMap { section -> [Line] in
                guard let value = sections[section] else {
                    return []
                }
                let comment = sectionComments[section].map { [Line(text: "# \($0)", keyPath: nil)] } ?? []
                return comment
                    + entryLines(
                        key: section, value: completed(value, forSection: section),
                        keyPath: [section], indent: 0)
            }
    }

    /// One section's body with every key of its schema present.
    ///
    /// The `Codable` synthesis leaves an optional property out of the
    /// encoding when it is `nil`, so `compaction.hardCeiling` and its
    /// kind would never reach the document. A person cannot edit a key
    /// they cannot see, and `config init` promises every key of the
    /// schema (cli-plan.md §5.11), so an absent key comes back here as
    /// `null` — the value the loader reads as the same absence, which
    /// keeps the round trip exact.
    ///
    /// - Parameters:
    ///   - value: The encoded section body.
    ///   - section: The section's YAML spelling.
    /// - Returns: The body with a `null` for each key the encoding left
    ///   out; `value` unchanged for a body that is not a mapping and for
    ///   the open-ended `tools:` roster, whose own keys always encode.
    private static func completed(_ value: Any, forSection section: String) -> Any {
        guard let mapping = value as? [String: Any],
            let schema = AgentConfiguration.sectionSchemas[section],
            case .checked(let knownKeys) = schema
        else {
            return value
        }
        return mapping.merging(knownKeys.map { ($0, NSNull() as Any) }) { present, _ in present }
    }

    /// `key: value` at `indent`, with a non-scalar value continued on the
    /// following lines.
    ///
    /// - Parameters:
    ///   - key: The mapping key.
    ///   - value: The `JSONSerialization` value to emit.
    ///   - keyPath: The key path of `key`, or `nil` inside a sequence item.
    ///   - indent: The indentation level of the key.
    /// - Returns: The lines of the entry.
    private static func entryLines(key: String, value: Any, keyPath: [String]?, indent: Int) -> [Line] {
        let pad = indentation(indent)
        let dotted = keyPath?.joined(separator: LoadedConfiguration.keyPathSeparator)
        if let scalar = scalarText(value) {
            return [Line(text: "\(pad)\(key): \(scalar)", keyPath: dotted)]
        }
        return [Line(text: "\(pad)\(key):", keyPath: dotted)]
            + childLines(of: value, keyPath: keyPath, indent: indent + 1)
    }

    /// The members of a non-empty mapping or sequence at `indent`.
    ///
    /// - Parameters:
    ///   - value: The mapping or sequence to emit.
    ///   - keyPath: The key path of `value`, or `nil` inside a sequence
    ///     item.
    ///   - indent: The indentation level of the members.
    /// - Returns: The lines of the members; none for a scalar.
    private static func childLines(of value: Any, keyPath: [String]?, indent: Int) -> [Line] {
        if let mapping = value as? [String: Any] {
            return mapping.keys.sorted().flatMap { key in
                entryLines(
                    key: key, value: mapping[key] ?? NSNull(), keyPath: keyPath.map { $0 + [key] },
                    indent: indent)
            }
        }
        if let sequence = value as? [Any] {
            return sequence.flatMap { sequenceItemLines($0, indent: indent) }
        }
        return []
    }

    /// One block-sequence item at `indent`: a scalar rides the dash, and a
    /// mapping or nested sequence hangs under a bare dash. No line of an
    /// item declares a key path — see ``Line``.
    ///
    /// - Parameters:
    ///   - value: The item to emit.
    ///   - indent: The indentation level of the dash.
    /// - Returns: The lines of the item.
    private static func sequenceItemLines(_ value: Any, indent: Int) -> [Line] {
        let pad = indentation(indent)
        if let scalar = scalarText(value) {
            return [Line(text: "\(pad)- \(scalar)", keyPath: nil)]
        }
        return [Line(text: "\(pad)-", keyPath: nil)] + childLines(of: value, keyPath: nil, indent: indent + 1)
    }

    /// The inline text of a scalar or an empty collection, or `nil` when the
    /// value needs block form on following lines.
    ///
    /// - Parameter value: The `JSONSerialization` value.
    /// - Returns: The inline text, or `nil` for a non-empty mapping or
    ///   sequence.
    private static func scalarText(_ value: Any) -> String? {
        if let number = value as? NSNumber {
            return numberText(number)
        }
        if let string = value as? String {
            return quoted(string)
        }
        if value is NSNull {
            return "null"
        }
        if let mapping = value as? [String: Any] {
            return mapping.isEmpty ? "{}" : nil
        }
        if let sequence = value as? [Any] {
            return sequence.isEmpty ? "[]" : nil
        }
        return nil
    }

    /// The YAML text of a JSON number, keeping a boolean, an integer and a
    /// floating-point value distinct so the loader re-resolves each as itself.
    ///
    /// - Parameter number: The `JSONSerialization` number.
    /// - Returns: `true`/`false`, an integer, or a floating-point literal.
    private static func numberText(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        let objCType = String(cString: number.objCType)
        if objCType == objCDoubleType || objCType == objCFloatType {
            return String(number.doubleValue)
        }
        return String(number.intValue)
    }

    /// A double-quoted, escaped scalar, so a value that carries a colon, a
    /// hash or a backslash stays one YAML scalar.
    ///
    /// - Parameter value: The string to quote.
    /// - Returns: The quoted scalar.
    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The indentation prefix of a level.
    ///
    /// - Parameter level: The indentation level.
    /// - Returns: The leading spaces.
    private static func indentation(_ level: Int) -> String {
        String(repeating: " ", count: level * indentWidth)
    }
}

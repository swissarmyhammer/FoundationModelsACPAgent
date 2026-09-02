import Foundation

/// Emits an ``AgentConfiguration`` as commented block YAML (plan.md §14.1,
/// §2.2). The `/config` builtin prints the text, and `/config export` writes
/// it to a layer's `config.yaml` — the §2.2 eject counterpart. The text
/// round-trips through ``ConfigurationLoader``: it names only schema keys, so
/// the loader reads it back to the same configuration.
///
/// The value tree comes from the configuration's own `Codable` encoding, so
/// the per-tool codecs (a disabled tool as `false`, the `mcp:` server list, a
/// transcript location word) each serialize exactly as the loader decodes
/// them. Every string scalar is emitted double-quoted, so a value that
/// carries YAML punctuation stays one scalar.
enum ConfigurationYAML {
    /// A shape the emitter cannot serialize.
    enum EmitError: Error, Equatable {
        /// The encoded configuration was not a mapping of sections.
        case notAMapping
    }

    /// The number of spaces one indentation level adds.
    private static let indentWidth = 2

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
    /// - Parameter configuration: The configuration to render.
    /// - Returns: The YAML document, newline-terminated.
    /// - Throws: ``EmitError/notAMapping`` when the encoded configuration is
    ///   not a mapping, or a `JSONEncoder`/`JSONSerialization` error.
    static func documentText(for configuration: AgentConfiguration) throws -> String {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
        guard let sections = encoded as? [String: Any] else {
            throw EmitError.notAMapping
        }
        var lines = [headerComment]
        for section in sectionOrder {
            guard let value = sections[section] else { continue }
            if let comment = sectionComments[section] {
                lines.append("# \(comment)")
            }
            appendEntry(key: section, value: value, indent: 0, into: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends `key: value` at `indent`, continuing a non-scalar value on the
    /// following lines.
    ///
    /// - Parameters:
    ///   - key: The mapping key.
    ///   - value: The `JSONSerialization` value to emit.
    ///   - indent: The indentation level of the key.
    ///   - lines: The line accumulator.
    private static func appendEntry(key: String, value: Any, indent: Int, into lines: inout [String]) {
        let pad = indentation(indent)
        if let scalar = scalarText(value) {
            lines.append("\(pad)\(key): \(scalar)")
            return
        }
        lines.append("\(pad)\(key):")
        appendChildren(of: value, indent: indent + 1, into: &lines)
    }

    /// Appends the members of a non-empty mapping or sequence at `indent`.
    ///
    /// - Parameters:
    ///   - value: The mapping or sequence to emit.
    ///   - indent: The indentation level of the members.
    ///   - lines: The line accumulator.
    private static func appendChildren(of value: Any, indent: Int, into lines: inout [String]) {
        if let mapping = value as? [String: Any] {
            for key in mapping.keys.sorted() {
                appendEntry(key: key, value: mapping[key] ?? NSNull(), indent: indent, into: &lines)
            }
        } else if let sequence = value as? [Any] {
            for element in sequence {
                appendSequenceItem(element, indent: indent, into: &lines)
            }
        }
    }

    /// Appends one block-sequence item at `indent`: a scalar rides the dash,
    /// and a mapping or nested sequence hangs under a bare dash.
    ///
    /// - Parameters:
    ///   - value: The item to emit.
    ///   - indent: The indentation level of the dash.
    ///   - lines: The line accumulator.
    private static func appendSequenceItem(_ value: Any, indent: Int, into lines: inout [String]) {
        let pad = indentation(indent)
        if let scalar = scalarText(value) {
            lines.append("\(pad)- \(scalar)")
            return
        }
        lines.append("\(pad)-")
        appendChildren(of: value, indent: indent + 1, into: &lines)
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

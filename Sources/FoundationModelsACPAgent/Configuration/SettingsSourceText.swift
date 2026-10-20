import Foundation
import FoundationModelsExtras

/// A settings change that the store refuses, because the write of the level
/// file cannot keep a template construct of the file (ACPA-17, D101).
public enum SettingsTemplateError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The change of `keyPath` touches a template construct that a write
    /// cannot keep: a block tag `{% %}` or a comment tag `{# #}` in the file,
    /// a templated key on the way to the key, or an expression that the
    /// write cannot put back. `keyPath` is the dotted key path of the change.
    case unkeptTemplate(keyPath: String)

    /// A human-readable reason that names the key path.
    public var description: String {
        switch self {
        case .unkeptTemplate(let keyPath):
            return
                "\(ConfigurationLoader.configFileName): the change of \"\(keyPath)\" is refused, because the file of the level holds a template construct that a write cannot keep"
        }
    }
}

/// The source text of one level file, before the render of its templates,
/// as a tree that a change can edit and a write can put back as text.
///
/// Each template expression `{{ ... }}` of the text becomes a token in the
/// tree: a plain scalar that holds no YAML punctuation. The write emits the
/// tree, then puts the original text of each expression back in place of
/// its token. Thus an expression such as `{{ TAVILY_API_KEY }}` stays an
/// expression in the file, and the file never gets the rendered value.
///
/// A block tag `{% ... %}` or a comment tag `{# ... #}` is not kept: the
/// tree has no place for it. A text that holds one gives no tree, and each
/// change of its level is refused.
struct SettingsSourceText {
    /// The start of each token. A text that holds it already gives no tree.
    private static let tokenPrefix = "acp_settings_template_"

    /// The end of each token, thus no token is the start of another token.
    private static let tokenSuffix = "_end"

    /// The markers of the template constructs that the tree cannot keep.
    private static let blockMarkers = ["{%", "{#"]

    /// The tree of the text, with a token in place of each expression, or
    /// `.null` for no text.
    let tree: YAMLValue

    /// The original text of each expression, by its token. A quoted scalar
    /// that holds only one expression keeps its quotes here.
    private let expressions: [String: String]

    /// The dotted key path of the change, for the error.
    private let keyPath: String

    /// Makes the source tree of `text`.
    ///
    /// - Parameters:
    ///   - text: The text of the level file, or `nil` for no file.
    ///   - keyPath: The key path of the change, for the error.
    /// - Throws: ``SettingsTemplateError/unkeptTemplate(keyPath:)`` when the
    ///   text holds a construct that the tree cannot keep, or when the text
    ///   with its tokens does not parse.
    init(text: String?, keyPath: [String]) throws {
        let dotted = keyPath.joined(separator: LoadedConfiguration.keyPathSeparator)
        self.keyPath = dotted
        guard let text else {
            tree = .null
            expressions = [:]
            return
        }
        guard !text.contains(Self.tokenPrefix), !Self.blockMarkers.contains(where: { text.contains($0) }) else {
            throw SettingsTemplateError.unkeptTemplate(keyPath: dotted)
        }
        let (protected, expressions) = Self.protecting(text)
        do {
            tree = try YAMLValue.parse(protected)
        } catch {
            throw SettingsTemplateError.unkeptTemplate(keyPath: dotted)
        }
        self.expressions = expressions
    }

    /// Refuses a change of `keyPath` that goes through a templated key, or
    /// below a value that is a template expression. The rendered name of a
    /// templated key is not known here, thus the change could add a second
    /// key for the same rendered name.
    ///
    /// - Parameter keyPath: The keys of the change from the root.
    /// - Throws: ``SettingsTemplateError/unkeptTemplate(keyPath:)``.
    func requireKeepable(_ keyPath: [String]) throws {
        var node = tree
        for key in keyPath {
            switch node {
            case .dictionary(let keys):
                guard !keys.keys.contains(where: Self.holdsToken) else {
                    throw SettingsTemplateError.unkeptTemplate(keyPath: self.keyPath)
                }
                guard let child = keys[key] else {
                    return
                }
                node = child
            case .string(let text) where Self.holdsToken(text):
                throw SettingsTemplateError.unkeptTemplate(keyPath: self.keyPath)
            case .null, .string, .int, .double, .bool, .array:
                return
            }
        }
    }

    /// The text of `changed`, a change of ``tree``, with the original text
    /// of each expression in place of its token.
    ///
    /// - Parameter changed: The changed tree.
    /// - Returns: The file text.
    /// - Throws: `ConfigurationYAML.EmitError` for a tree that is not a
    ///   mapping; ``SettingsTemplateError/unkeptTemplate(keyPath:)`` for an
    ///   expression inside a longer scalar that the double-quoted form of the
    ///   emitter cannot hold as it is.
    func text(of changed: YAMLValue) throws -> String {
        var text = try ConfigurationYAML.levelText(of: changed)
        for (token, original) in expressions {
            text = text.replacingOccurrences(of: "\"\(token)\"", with: original)
            guard text.contains(token) else {
                continue
            }
            guard !original.contains("\""), !original.contains("\\") else {
                throw SettingsTemplateError.unkeptTemplate(keyPath: keyPath)
            }
            text = text.replacingOccurrences(of: token, with: original)
        }
        return text
    }

    /// `text` with a token in place of each expression, and the original
    /// text of each expression by its token.
    ///
    /// An expression that a quoted scalar holds alone is taken with its
    /// quotes, thus the tree holds the token as the whole scalar.
    ///
    /// - Parameter text: The text of the level file.
    /// - Returns: The text with the tokens, and the expressions.
    private static func protecting(_ text: String) -> (text: String, expressions: [String: String]) {
        let expressionPattern = /"\{\{[^"\n]*?\}\}"|'\{\{[^'\n]*?\}\}'|\{\{[^\n]*?\}\}/
        var protected = ""
        var expressions: [String: String] = [:]
        var cursor = text.startIndex
        for match in text.matches(of: expressionPattern) {
            let token = "\(tokenPrefix)\(expressions.count)\(tokenSuffix)"
            protected += text[cursor..<match.range.lowerBound] + token
            expressions[token] = String(text[match.range])
            cursor = match.range.upperBound
        }
        protected += text[cursor...]
        return (protected, expressions)
    }

    /// Whether `text` holds a token.
    ///
    /// - Parameter text: A key or a string scalar of the tree.
    /// - Returns: `true` when the text holds a token.
    private static func holdsToken(_ text: String) -> Bool {
        text.contains(tokenPrefix)
    }
}

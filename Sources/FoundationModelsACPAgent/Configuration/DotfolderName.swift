/// Why a string was refused as a dotfolder name (plan.md §2.1).
public enum DotfolderNameError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The name is the empty string.
    case empty
    /// The name contains `/` or `\`, so it would add path components.
    case containsPathSeparator(name: String)
    /// The name is `.` or `..`, a directory reference and not a name.
    case directoryReference(name: String)
    /// The name starts with `.`. The project layer adds the dot itself.
    case leadingDot(name: String)

    /// A human-readable reason that names the refused string.
    public var description: String {
        switch self {
        case .empty:
            return "dotfolder name must not be empty"
        case .containsPathSeparator(let name):
            return "dotfolder name \"\(name)\" must not contain a path separator"
        case .directoryReference(let name):
            return "dotfolder name \"\(name)\" must not be a directory reference"
        case .leadingDot(let name):
            return "dotfolder name \"\(name)\" must not start with a dot"
        }
    }
}

/// The frontend-supplied `<name>` that roots the configuration stack and the
/// transcript directory (plan.md §2.1): a bare word such as `"coding"`.
///
/// The name becomes a path component under the user config directory and,
/// with a leading dot added, under the session working directory. So a name
/// that could leave its directory is refused at construction, never later:
/// the empty string, a `/` or `\`, the references `.` and `..`, and a
/// leading `.`.
public struct DotfolderName: Sendable, Hashable, CustomStringConvertible {
    /// The characters that separate path components on any supported host.
    private static let pathSeparators: Set<Character> = ["/", "\\"]

    /// The two names that reference a directory instead of naming one.
    private static let directoryReferences: Set<String> = [".", ".."]

    /// The character the project layer prepends, so a caller must not.
    private static let dot: Character = "."

    /// The validated bare name.
    public let rawValue: String

    /// Validates `rawValue` and keeps it when it is safe as a path component.
    ///
    /// - Parameter rawValue: The bare name, e.g. `"coding"`.
    /// - Throws: `DotfolderNameError` when `rawValue` is empty, contains a
    ///   path separator, is `.` or `..`, or starts with `.`.
    public init(_ rawValue: String) throws(DotfolderNameError) {
        guard !rawValue.isEmpty else {
            throw .empty
        }
        guard !rawValue.contains(where: Self.pathSeparators.contains) else {
            throw .containsPathSeparator(name: rawValue)
        }
        guard !Self.directoryReferences.contains(rawValue) else {
            throw .directoryReference(name: rawValue)
        }
        guard rawValue.first != Self.dot else {
            throw .leadingDot(name: rawValue)
        }
        self.rawValue = rawValue
    }

    /// The bare name.
    public var description: String { rawValue }
}

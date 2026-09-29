import Foundation
import Testing

/// The guard against the unified logging API of the OS.
///
/// Each log record of the agent goes through swift-log, so the backend that
/// the executable bootstraps gets it, and a `TelemetryCapture` of a test sees
/// it. An `os.Logger` or an `OSSignposter` writes past that backend. A global
/// or a `static let` logger keeps the handler of the time when it was made,
/// thus it writes past a bootstrap or a capture that comes later.
///
/// This suite reads each `.swift` file under `Sources/`, and it fails when a
/// line has one of the forbidden forms. The unit job of CI runs `swift test`
/// at the root, so CI runs this guard on each change.
@Suite struct NoUnifiedLoggingTests {
    /// One forbidden form: the name that a failure shows, and the regular
    /// expression that finds the form in one line of source.
    struct ForbiddenForm: Sendable {
        /// The name of the form, for the failure message.
        let name: String

        /// The regular expression that matches a line with the form.
        let pattern: String
    }

    /// One line of source that has a forbidden form.
    struct Violation: CustomStringConvertible {
        /// The path of the file, relative to `Sources/`.
        let file: String

        /// The line number, from 1.
        let line: Int

        /// The name of the forbidden form.
        let form: String

        /// The text that a failure shows for this violation.
        var description: String { "\(file):\(line): \(form)" }
    }

    /// The name of the directory that holds the source of each product.
    private static let sourcesDirectoryName = "Sources"

    /// The file extension of a Swift source file.
    private static let swiftExtension = "swift"

    /// The text at the start of a comment line.
    private static let commentPrefix = "//"

    /// The pattern of a stored declaration whose type is the swift-log
    /// `Logger`, after its `let` or `var` keyword: the name, then a type
    /// annotation or an initializer call. `Logger.Level` and
    /// `Logger.Metadata` do not match.
    private static let loggerDeclarationTail =
        #"(?:let|var)\s+\w+\s*(?::\s*(?:Logging\.)?Logger(?![\w.])|=\s*(?:Logging\.)?Logger\()"#

    /// Each form that no source file may have.
    static let forbiddenForms = [
        ForbiddenForm(
            name: "import os",
            pattern: #"^\s*(?:@\w+\s+)*import\s+(?:\w+\s+)?(?:os|OSLog)\b"#),
        ForbiddenForm(name: "os.Logger", pattern: #"\bos\.Logger\b"#),
        ForbiddenForm(name: "Logger(subsystem:", pattern: #"\bLogger\(\s*subsystem:"#),
        ForbiddenForm(name: "OSSignposter", pattern: #"\bOSSignposter\b"#),
        ForbiddenForm(
            name: "a global Logger",
            pattern:
                #"^(?:(?:public|package|internal|fileprivate|private|nonisolated(?:\(unsafe\))?)\s+)*"#
                + loggerDeclarationTail),
        ForbiddenForm(
            name: "a static Logger",
            pattern: #"\b(?:static|class)\s+"# + loggerDeclarationTail),
    ]

    /// Lines that the scan must find, with the name of the form in each.
    static let forbiddenLines: [(line: String, form: String)] = [
        ("import os", "import os"),
        ("@preconcurrency import os.log", "import os"),
        ("import OSLog", "import os"),
        ("let log = os.Logger()", "os.Logger"),
        (#"    let logger = Logger(subsystem: "a", category: "b")"#, "Logger(subsystem:"),
        ("    let signposter = OSSignposter()", "OSSignposter"),
        (#"let transcriptLogger = Logger(label: "a")"#, "a global Logger"),
        ("private let log: Logger = makeLogger()", "a global Logger"),
        (#"    static let logger = Logger(label: "a")"#, "a static Logger"),
        ("    private static let logger: Logging.Logger = makeLogger()", "a static Logger"),
    ]

    /// Lines that the scan must not find.
    static let allowedLines = [
        "import Foundation",
        "import Logging",
        "    static let standardErrorLogLevel: Logger.Level = .warning",
        "    static func sessionMetadata(_ sessionId: SessionId) -> Logger.Metadata {",
        #"        Logger(label: moduleName + "." + category.rawValue)"#,
        #"        let logger = Logger(label: "a")"#,
        "/// Do not use os.Logger or OSSignposter here.",
    ]

    /// No file under `Sources/` has a forbidden form.
    @Test func noSourceFileUsesUnifiedLoggingOrAKeptLogger() throws {
        let sources = try PackageRoot.directory()
            .appendingPathComponent(Self.sourcesDirectoryName)

        let violations = try Self.violations(under: sources)

        #expect(violations.isEmpty, "\(violations.map(\.description).joined(separator: "\n"))")
    }

    /// The scan finds each forbidden form, so the guard above cannot pass
    /// because its patterns match nothing.
    @Test(arguments: forbiddenLines)
    func theScanFindsAForbiddenLine(line: String, form: String) throws {
        let found = try Self.violations(inText: line, file: #function)

        #expect(found.map(\.form) == [form])
    }

    /// The scan does not find the swift-log forms that the agent uses.
    @Test(arguments: allowedLines)
    func theScanAllowsASwiftLogLine(line: String) throws {
        #expect(try Self.violations(inText: line, file: #function).isEmpty)
    }

    // MARK: - The scan

    /// Each violation in each `.swift` file under `directory`.
    ///
    /// - Parameter directory: The directory to walk, at any depth.
    /// - Returns: The violations, sorted by file and line.
    /// - Throws: The directory-read error, the file-read error, or the
    ///   error of a pattern that does not compile.
    private static func violations(under directory: URL) throws -> [Violation] {
        let relativePaths = try FileManager.default
            .subpathsOfDirectory(atPath: directory.path)
            .filter { URL(fileURLWithPath: $0).pathExtension == swiftExtension }
            .sorted()
        return try relativePaths.flatMap { relativePath in
            let text = try String(
                contentsOf: directory.appendingPathComponent(relativePath), encoding: .utf8)
            return try violations(inText: text, file: relativePath)
        }
    }

    /// Each violation in `text`. A comment line is not code, so the scan
    /// does not read it.
    ///
    /// Each pattern uses the simple word boundary. The default Unicode word
    /// boundary does not break between `os` and `.log`, so `\b` would not
    /// find `import os.log`.
    ///
    /// - Parameters:
    ///   - text: The source text.
    ///   - file: The file name that each violation shows.
    /// - Returns: One violation for each line and each form that it has.
    /// - Throws: The error of a pattern that does not compile.
    private static func violations(inText text: String, file: String) throws -> [Violation] {
        let compiledForms = try forbiddenForms.map {
            (name: $0.name, regex: try Regex($0.pattern).wordBoundaryKind(.simple))
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix(commentPrefix) }
            .flatMap { index, line in
                compiledForms
                    .filter { line.contains($0.regex) }
                    .map { Violation(file: file, line: index + 1, form: $0.name) }
            }
    }
}

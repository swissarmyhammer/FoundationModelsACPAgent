import ArgumentParser
import Foundation
import FoundationModelsACPAgent
import FoundationModelsExtras

extension AcpAgentCommand {
    /// `acp-agent config`: nothing is on disk after an install, so the
    /// configuration is invisible, and these subcommands make it visible
    /// (cli-plan.md §5.11). `show` and `path` report; `init` and `edit`
    /// are stubs until their card lands, and each exits 1.
    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "Show, write, locate or edit the configuration.",
            subcommands: [Show.self, Init.self, Path.self, Edit.self])

        /// `config show`: print the merged configuration, and where each
        /// value came from. The report goes to stdout (§5.6), and each
        /// configuration warning goes to stderr.
        struct Show: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "show",
                abstract: "Print the merged configuration, and where each value came from.",
                discussion:
                    "The report goes to stdout. A configuration warning, such as an unknown section, goes to stderr."
            )

            /// The `--json --source` document: JSON carries no comment, so
            /// the layer of each key sits beside the tree.
            private struct AnnotatedDocument: Encodable {
                /// The merged configuration.
                let configuration: AgentConfiguration

                /// The layer of every key, by dotted key path.
                let sources: [String: ConfigurationLayerName]
            }

            /// The `--cwd` option (§5.10).
            @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

            /// Whether each key names the layer that set it.
            @Flag(
                name: .customLong("source"),
                help:
                    "Annotate each key with the layer that set it: builtin, user or project. With --json, the document holds the tree under \"configuration\" and the layer of each key under \"sources\"."
            )
            var annotatesSource = false

            /// Whether the tree is JSON in place of YAML.
            @Flag(name: .customLong("json"), help: "Print the same tree as JSON.")
            var asJSON = false

            mutating func run() throws {
                try report(environment: ProcessInfo.processInfo.environment).write()
            }

            /// Builds the report: the merged configuration of `--cwd`'s
            /// stack in the form the flags select, and the load warnings.
            ///
            /// - Parameter environment: The environment the stack reads
            ///   `XDG_CONFIG_HOME` from.
            /// - Returns: The report.
            /// - Throws: `DotfolderNameError`, the configuration load
            ///   error, or the encoding error.
            func report(environment: [String: String]) throws -> CommandReport {
                let loaded = try AgentComposition.makeConfigurationLoader(
                    workingDirectory: workingDirectoryOptions.directoryURL, environment: environment
                ).load()
                return CommandReport(
                    standardOutput: try documentText(for: loaded),
                    standardErrorLines: loaded.warnings.map(\.description))
            }

            /// The document the flags select: YAML, or JSON under `--json`,
            /// each with the layer of every key under `--source`.
            private func documentText(for loaded: LoadedConfiguration) throws -> String {
                if asJSON {
                    return try annotatesSource
                        ? Self.jsonText(
                            of: AnnotatedDocument(
                                configuration: loaded.configuration, sources: try Self.layerNames(of: loaded)))
                        : Self.jsonText(of: loaded.configuration)
                }
                return try ConfigurationYAML.documentText(
                    for: loaded.configuration, annotation: annotatesSource ? .sources(loaded.sources) : .none)
            }

            /// The JSON text of `document`: pretty, keys sorted, slashes
            /// plain, newline-terminated.
            ///
            /// - Parameter document: The value to encode.
            /// - Returns: The JSON text.
            /// - Throws: The encoding error.
            private static func jsonText(of document: some Encodable) throws -> String {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                return String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
            }

            /// The layer of every key of `loaded`'s tree, by dotted key
            /// path: the loader's entry, or `builtin` for a key no layer
            /// set.
            ///
            /// - Parameter loaded: The load to name the layers of.
            /// - Returns: One entry per key path of the tree.
            /// - Throws: What `ConfigurationYAML.keyPaths(of:)` throws.
            private static func layerNames(of loaded: LoadedConfiguration) throws
                -> [String: ConfigurationLayerName]
            {
                let entries = try ConfigurationYAML.keyPaths(of: loaded.configuration).map {
                    ($0, ConfigurationLayerName(loaded.sources[$0]))
                }
                return Dictionary(entries, uniquingKeysWith: { first, _ in first })
            }
        }

        /// `config init`: write a `config.yaml` with every key at its
        /// default.
        struct Init: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "init",
                abstract: "Write a config.yaml with every key at its default.")

            mutating func run() throws {
                throw NotImplementedError(command: Self.self)
            }
        }

        /// `config path`: print each layer path, one per line, with a mark
        /// for the ones that exist. Plain text on stdout (§5.6): this is a
        /// report, and a report is data, so no renderer and no escape
        /// sequence touches it.
        struct Path: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "path",
                abstract: "Print each layer path, and say which ones exist.")

            /// Where a layer lives.
            private enum Location {
                /// In code: the builtin defaults have no file.
                case code

                /// A directory on disk, which exists or is missing.
                case directory(path: String, exists: Bool)

                /// The directory path, or `nil` for the layer in code.
                var directoryPath: String? {
                    switch self {
                    case .code:
                        return nil
                    case .directory(let path, _):
                        return path
                    }
                }
            }

            /// One row of the report: the layer, and where it lives.
            private struct Row {
                /// The layer name, the first column.
                let layer: ConfigurationLayerName

                /// Where the layer lives, the other columns.
                let location: Location
            }

            /// The path column of the builtin row.
            private static let codeLocation = "(in code, no file)"

            /// The mark of a layer directory that is on disk.
            private static let existsMark = "exists"

            /// The mark of a layer directory that is not on disk.
            private static let missingMark = "missing"

            /// The suffix a layer path carries, because a layer is a
            /// directory.
            private static let directorySuffix = "/"

            /// The spaces between one column and the next.
            private static let columnGap = 2

            /// The `--cwd` option (§5.10).
            @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

            mutating func run() throws {
                try report(environment: ProcessInfo.processInfo.environment).write()
            }

            /// Builds the report: the builtin row, then one row per layer
            /// of `--cwd`'s stack, lowest precedence first.
            ///
            /// - Parameter environment: The environment the stack reads
            ///   `XDG_CONFIG_HOME` from.
            /// - Returns: The report, with nothing for stderr.
            /// - Throws: `DotfolderNameError` when the dotfolder name is
            ///   refused.
            func report(environment: [String: String]) throws -> CommandReport {
                let stack = try AgentComposition.makeConfigurationLoader(
                    workingDirectory: workingDirectoryOptions.directoryURL, environment: environment
                ).stack
                let rows = [Row(layer: .builtin, location: .code)] + stack.layers.map(Self.row(for:))
                return CommandReport(standardOutput: Self.table(of: rows), standardErrorLines: [])
            }

            /// The row of one stack layer: its name, its root as a
            /// directory path, and whether that directory is on disk.
            private static func row(for layer: DotfolderStack.Layer) -> Row {
                Row(
                    layer: ConfigurationLayerName(layer.source),
                    location: .directory(
                        path: layer.root.path + directorySuffix, exists: isDirectory(layer.root)))
            }

            /// Whether `url` is a directory on disk.
            private static func isDirectory(_ url: URL) -> Bool {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }

            /// The rows as aligned columns, one line each, newline-terminated.
            /// The path column is as wide as the widest directory path; the
            /// builtin row's text sits in that column and has no mark.
            private static func table(of rows: [Row]) -> String {
                let layerWidth = columnWidth(of: rows.map(\.layer.rawValue))
                let pathWidth = columnWidth(of: rows.compactMap(\.location.directoryPath))
                return rows.map { line(of: $0, layerWidth: layerWidth, pathWidth: pathWidth) }
                    .joined(separator: "\n") + "\n"
            }

            /// The width of a column: the widest cell, plus the gap.
            private static func columnWidth(of cells: [String]) -> Int {
                (cells.map(\.count).max() ?? 0) + columnGap
            }

            /// One line: the layer name padded to `layerWidth`, then the
            /// location text, then, for a directory, the path padded to
            /// `pathWidth` and its mark.
            private static func line(of row: Row, layerWidth: Int, pathWidth: Int) -> String {
                let name = padded(row.layer.rawValue, to: layerWidth)
                switch row.location {
                case .code:
                    return name + codeLocation
                case .directory(let path, let exists):
                    return name + padded(path, to: pathWidth) + (exists ? existsMark : missingMark)
                }
            }

            /// `text` followed by spaces up to `width`.
            private static func padded(_ text: String, to width: Int) -> String {
                text.padding(toLength: width, withPad: " ", startingAt: 0)
            }
        }

        /// `config edit`: open the nearest `config.yaml` in `$EDITOR`.
        struct Edit: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "edit",
                abstract: "Open the nearest config.yaml in $EDITOR.")

            mutating func run() throws {
                throw NotImplementedError(command: Self.self)
            }
        }
    }
}

import ArgumentParser
import Foundation
import FoundationModelsACPAgent
import FoundationModelsExtras

extension AcpAgentCommand {
    /// `acp-agent config`: nothing is on disk after an install, so the
    /// configuration is invisible, and these four subcommands make it
    /// visible and editable (cli-plan.md §5.11). `show` and `path`
    /// report; `init` and `edit` write.
    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "Show, write, locate or edit the configuration.",
            subcommands: [Show.self, Init.self, Path.self, Edit.self])

        /// Writes a `config.yaml` with every key at its default into one
        /// layer — the body of `config init`, which `config edit` runs
        /// too when no layer holds a file.
        ///
        /// **Nothing here is new.** The text comes from
        /// ``ConfigurationYAML``, the one generator the `/config export`
        /// slash command also writes through, so the two front doors
        /// cannot drift (cli-plan.md §5.11). The file goes through
        /// ``LayerFileWriter``, the one writer `instructions eject` also
        /// writes through, so the overwrite guard is one guard.
        ///
        /// - Parameters:
        ///   - selection: Which layer receives the file.
        ///   - stack: The stack whose layer roots the file goes into.
        ///   - overwrites: Whether a `config.yaml` that is already in the
        ///     layer is replaced.
        /// - Returns: The path the file was written to.
        /// - Throws: What ``ConfigurationYAML/documentText(for:annotation:)``
        ///   throws, or what
        ///   ``LayerFileWriter/write(_:named:into:of:overwrites:)`` throws
        ///   — above all the refusal to overwrite.
        static func writeDefaultConfiguration(
            into selection: LayerSelection, of stack: DotfolderStack, overwrites: Bool
        ) throws -> URL {
            try LayerFileWriter.write(
                try ConfigurationYAML.documentText(for: AgentConfiguration()),
                named: ConfigurationLoader.configFileName,
                into: selection, of: stack, overwrites: overwrites)
        }

        /// The layer stack of the directory `--cwd` names.
        ///
        /// **One composition, three subcommands.** `init`, `path` and
        /// `edit` each want the stack and nothing else, so they compose
        /// it here, and the three cannot drift apart. `show` wants the
        /// merged values, so it composes the same loader and reads it
        /// with `load()`.
        ///
        /// - Parameters:
        ///   - options: The `--cwd` option group of the subcommand.
        ///   - environment: The environment the stack reads
        ///     `XDG_CONFIG_HOME` from.
        /// - Returns: The stack of layers.
        /// - Throws: `DotfolderNameError` when the dotfolder name is
        ///   refused.
        private static func makeStack(
            for options: WorkingDirectoryOptions, environment: [String: String]
        ) throws -> DotfolderStack {
            try AgentComposition.makeConfigurationLoader(
                workingDirectory: options.directoryURL, environment: environment
            ).stack
        }

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
        /// default, each under the comment of its section.
        ///
        /// Nothing is on disk after an install, so this is how a person
        /// gets a file to edit. The file the command writes reads back
        /// through `ConfigurationLoader` to exactly the builtin
        /// configuration, so a fresh `config.yaml` changes no behavior
        /// until the person changes a value in it.
        struct Init: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "init",
                abstract: "Write a config.yaml with every key at its default.",
                discussion: """
                    The written path goes to stdout. The command refuses to \
                    replace a config.yaml that is already in the layer, and it \
                    names the flag that permits the replacement.
                    """)

            /// The `--cwd` option (§5.10).
            @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

            /// Which layer receives the file. The project layer is the
            /// default, which matches `instructions eject`.
            @Flag var layer: LayerSelection = .project

            /// Whether a `config.yaml` that is already in the layer is
            /// replaced.
            @Flag(
                name: .customLong(LayerFileWriter.forceFlagName),
                help: "Replace a config.yaml that is already in the layer."
            )
            var overwrites = false

            mutating func run() throws {
                try report(environment: ProcessInfo.processInfo.environment).write()
            }

            /// Writes the file and builds the report: the written path, and
            /// nothing for stderr.
            ///
            /// - Parameter environment: The environment the stack reads
            ///   `XDG_CONFIG_HOME` from.
            /// - Returns: The report.
            /// - Throws: `DotfolderNameError` when the dotfolder name is
            ///   refused, or what
            ///   ``Config/writeDefaultConfiguration(into:of:overwrites:)``
            ///   throws — above all the refusal to overwrite.
            func report(environment: [String: String]) throws -> CommandReport {
                let stack = try Config.makeStack(
                    for: workingDirectoryOptions, environment: environment)
                let url = try Config.writeDefaultConfiguration(
                    into: layer, of: stack, overwrites: overwrites)
                return CommandReport(standardOutput: url.path + "\n", standardErrorLines: [])
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
                let stack = try Config.makeStack(
                    for: workingDirectoryOptions, environment: environment)
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
        ///
        /// "Nearest" is the stack's own word: the highest-precedence
        /// layer that holds the file wins, so a project `config.yaml`
        /// beats a user one. With no file in any layer the command runs
        /// the `config init` body first and says so on stderr, because a
        /// person who asks to edit the configuration means to edit it,
        /// not to be told there is nothing there.
        ///
        /// The editor owns the terminal while it runs, so this command
        /// writes nothing to stdout: the notice is the whole report, and
        /// it goes to stderr (§5.6).
        struct Edit: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "edit",
                abstract: "Open the nearest config.yaml in $EDITOR.",
                discussion: """
                    With no config.yaml in any layer the command writes the \
                    defaults into the project layer first, and says so on \
                    stderr. With no EDITOR it stops and names the variable, \
                    and it changes no file.
                    """)

            /// What one `config edit` resolved before the editor opens.
            struct Plan {
                /// The `config.yaml` the editor opens.
                let file: URL

                /// The editor command, as the person spelled it in
                /// `$EDITOR`.
                let editorCommand: String

                /// What to say before the editor opens: the notice that
                /// this command had to write the file first, on stderr,
                /// or nothing when a layer already held it.
                let report: CommandReport
            }

            /// The layer a missing `config.yaml` is written into: the one
            /// `config init` writes by default.
            private static let layerForAMissingFile = LayerSelection.project

            /// What this command writes to stdout: nothing at all. The
            /// editor owns the terminal once it opens, so the whole
            /// report is the stderr notice (§5.6).
            private static let emptyStandardOutput = ""

            /// The report of an edit that had nothing to say, because a
            /// layer already held the file.
            private static let silentReport = CommandReport(
                standardOutput: emptyStandardOutput, standardErrorLines: [])

            /// The `--cwd` option (§5.10).
            @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

            mutating func run() throws {
                let plan = try self.plan(environment: ProcessInfo.processInfo.environment)
                plan.report.write()
                try EditorLauncher.open(plan.file, with: plan.editorCommand)
            }

            /// Resolves the file to open and the editor to open it with,
            /// and writes the defaults when no layer holds a file.
            ///
            /// **The editor is resolved first, on purpose.** A command
            /// that cannot open an editor must change no file, so the
            /// refusal comes before the write.
            ///
            /// - Parameter environment: The environment the editor and
            ///   the stack are read from.
            /// - Returns: The plan.
            /// - Throws: ``EditorNotNamedError`` when the environment
            ///   names no editor, `DotfolderNameError` when the dotfolder
            ///   name is refused, or the write error of the defaults.
            func plan(environment: [String: String]) throws -> Plan {
                let editorCommand = try EditorLauncher.command(in: environment)
                let stack = try Config.makeStack(
                    for: workingDirectoryOptions, environment: environment)
                if let file = stack.nearest(ConfigurationLoader.configFileName) {
                    return Plan(
                        file: file, editorCommand: editorCommand, report: Self.silentReport)
                }
                let written = try Config.writeDefaultConfiguration(
                    into: Self.layerForAMissingFile, of: stack, overwrites: false)
                return Plan(
                    file: written, editorCommand: editorCommand,
                    report: Self.noticeReport(forWritten: written))
            }

            /// The report of an edit that had to write the file first: the
            /// notice on stderr, and nothing on stdout.
            ///
            /// - Parameter written: The path the defaults were written to.
            /// - Returns: The report.
            private static func noticeReport(forWritten written: URL) -> CommandReport {
                CommandReport(
                    standardOutput: emptyStandardOutput,
                    standardErrorLines: [
                        "no layer holds a \(ConfigurationLoader.configFileName); "
                            + "wrote the defaults to \(written.path)"
                    ])
            }
        }
    }
}

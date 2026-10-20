import ArgumentParser
import Foundation
import FoundationModelsACPAgent

extension AcpAgentCommand {
    /// `acp-agent snapshots`: list and remove the snapshot folders.
    ///
    /// The agent keeps the shadow folder of each snapshot session key after
    /// the session ends, and no sweep at start removes a folder: many
    /// sessions can work in one folder at the same time, and a sweep can
    /// remove the snapshots of a session that another process runs. The user
    /// lists the folders with `list` and removes the ones that they select
    /// with `remove`. The library ``SnapshotInventory`` does the work, thus a
    /// test or another host uses it with no CLI.
    struct Snapshots: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "snapshots",
            abstract: "List and remove the snapshot folders.",
            subcommands: [List.self, Remove.self])

        /// The inventory of the CLI: the snapshots in the hook data directory
        /// of the dotfolder name (``AgentHooks/dataDirectory(name:environment:)``),
        /// and the project registry and the project settings of the XDG
        /// layers, as `acp-agent acp` reads them.
        ///
        /// - Parameter environment: The environment that `XDG_DATA_HOME` and
        ///   `XDG_CONFIG_HOME` are read from.
        /// - Returns: The inventory. The call reads no file.
        /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
        static func makeInventory(environment: [String: String]) throws -> SnapshotInventory {
            let name = try DotfolderName(AgentComposition.dotfolderName)
            return SnapshotInventory(
                hooksDataDirectory: AgentHooks.dataDirectory(name: name, environment: environment),
                settingsStore: SettingsStore(settingsFolders: SettingsFolders(name: name, environment: environment)))
        }

        /// `snapshots list`: one line for each snapshot folder, or one JSON
        /// array with `--json`.
        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List each snapshot folder.",
                discussion: """
                    Each line has the session key, the number of checkpoints, the time of \
                    the last checkpoint, recorded or unrecorded, and the working directory, \
                    separated by tabs. A dash is in place of a value that the folder does \
                    not have. "recorded" tells that the sessions.jsonl of a registered \
                    project has the session. A warning goes to stderr.
                    """)

            /// The separator between the fields of a line.
            private static let fieldSeparator = "\t"

            /// The text in place of a value that the folder does not have.
            private static let missingValue = "-"

            /// Whether the listing goes to stdout as JSON in place of lines.
            @Flag(
                name: .customLong("json"),
                help: "Write the listing to stdout as one JSON array.")
            var asJSON = false

            mutating func run() async throws {
                try await report(environment: ProcessInfo.processInfo.environment).write()
            }

            /// Reads the inventory and builds the report: the listing on
            /// stdout, and each warning on stderr.
            ///
            /// - Parameter environment: The environment that the inventory
            ///   reads the folders from.
            /// - Returns: The report.
            /// - Throws: `DotfolderNameError`, the read error of the snapshot
            ///   directory, or the encoding error.
            func report(environment: [String: String]) async throws -> CommandReport {
                let listing = try await Snapshots.makeInventory(environment: environment).list()
                return CommandReport(
                    standardOutput: asJSON
                        ? try JSONDocument.text(of: listing.entries) : Self.lines(of: listing.entries),
                    standardErrorLines: listing.warnings.map(\.description))
            }

            /// The text listing: one newline-terminated line for each entry.
            ///
            /// - Parameter entries: The entries of the inventory.
            /// - Returns: The lines, or the empty text for no entry.
            private static func lines(of entries: [SnapshotInventoryEntry]) -> String {
                entries.map { line(of: $0) + "\n" }.joined()
            }

            /// The line of one entry: its fields, separated by tabs.
            ///
            /// - Parameter entry: The entry.
            /// - Returns: The line, with no newline.
            private static func line(of entry: SnapshotInventoryEntry) -> String {
                [
                    entry.sessionKey,
                    entry.checkpointCount.map(String.init) ?? missingValue,
                    entry.lastCheckpointDate.map { $0.formatted(.iso8601) } ?? missingValue,
                    entry.recordedState.rawValue,
                    entry.workingDirectory ?? missingValue,
                ].joined(separator: fieldSeparator)
            }
        }

        /// `snapshots remove`: remove the named keys, or each unrecorded key.
        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "remove",
                abstract: "Remove snapshot folders.",
                discussion: """
                    Give one or more session keys, or --unrecorded for each key that the \
                    sessions.jsonl of no registered project has. Each removed key goes to \
                    stdout. A key with no snapshot folder, or a key whose remove fails, goes \
                    to stderr; the command continues with the next key, and the exit status \
                    is 1. The command cannot see a session that a running agent has open: \
                    stop the agent of a key before you remove the key.
                    """)

            /// The result of one `remove`: the report and the exit code.
            struct Outcome {
                /// The removed keys for stdout, and the errors and the
                /// warnings for stderr.
                let report: CommandReport

                /// ``AgentExitCode/success``, or ``AgentExitCode/error`` when
                /// a key was not removed or the command refused to remove.
                let exitCode: AgentExitCode
            }

            /// The usage error of a command with no key and no `--unrecorded`.
            private static let noSelectionMessage = "Give one or more session keys, or --unrecorded."

            /// The usage error of a command with keys and `--unrecorded`.
            private static let twoSelectionsMessage = "Give session keys or --unrecorded, not both."

            /// The text after the key on the stderr line of a key that has no
            /// snapshot folder.
            private static let noSnapshotFolderText = "no snapshot folder"

            /// The stderr line of a `--unrecorded` that removes nothing,
            /// because the recorded state of the keys is not known.
            private static let unknownStateRefusal =
                "The command removed no key: a recorded key can show as unrecorded."

            /// The keys to remove.
            @Argument(help: "The session keys of the snapshot folders to remove.")
            var sessionKeys: [String] = []

            /// Whether the command removes each unrecorded key.
            @Flag(
                name: .customLong("unrecorded"),
                help: "Remove each key that the sessions.jsonl of no registered project has.")
            var removesUnrecordedKeys = false

            /// Refuses a command that selects no key, or that selects keys in
            /// two ways. ArgumentParser gives the refusal as a usage error,
            /// before the command removes a folder.
            ///
            /// - Throws: `ValidationError` for no selection or for two
            ///   selections.
            func validate() throws {
                let namesKeys = !sessionKeys.isEmpty
                guard namesKeys != removesUnrecordedKeys else {
                    throw ValidationError(namesKeys ? Self.twoSelectionsMessage : Self.noSelectionMessage)
                }
            }

            mutating func run() async throws {
                let outcome = try await outcome(environment: ProcessInfo.processInfo.environment)
                outcome.report.write()
                guard outcome.exitCode == .success else {
                    throw outcome.exitCode.parserError
                }
            }

            /// Removes the selected keys and builds the outcome.
            ///
            /// With `--unrecorded` the command reads the inventory first. When
            /// a warning makes the recorded state unknown, the command removes
            /// nothing, because a recorded key can show as unrecorded.
            ///
            /// - Parameter environment: The environment that the inventory
            ///   reads the folders from.
            /// - Returns: The outcome.
            /// - Throws: `DotfolderNameError`, or the read error of the
            ///   snapshot directory.
            func outcome(environment: [String: String]) async throws -> Outcome {
                let inventory = try Snapshots.makeInventory(environment: environment)
                guard removesUnrecordedKeys else {
                    return Self.outcome(of: try await inventory.remove(sessionKeys: sessionKeys), warnings: [])
                }
                let listing = try await inventory.list()
                let warnings = listing.warnings.map(\.description)
                guard listing.isRecordedStateKnown else {
                    return Outcome(
                        report: CommandReport(standardOutput: "", standardErrorLines: warnings + [Self.unknownStateRefusal]),
                        exitCode: .error)
                }
                return Self.outcome(
                    of: try await inventory.remove(sessionKeys: listing.unrecordedKeys), warnings: warnings)
            }

            /// The outcome of the removes: each removed key on stdout; each
            /// warning, each key with no snapshot folder and each failed key
            /// on stderr; and the exit code 1 when a key was not removed.
            ///
            /// - Parameters:
            ///   - removals: The outcome of each key, in order.
            ///   - warnings: The warnings of the inventory read.
            /// - Returns: The outcome.
            private static func outcome(of removals: [SnapshotRemovalOutcome], warnings: [String]) -> Outcome {
                let removedKeys = removals.compactMap(removedKey(of:))
                let errorLines = removals.compactMap(errorLine(of:))
                return Outcome(
                    report: CommandReport(
                        standardOutput: removedKeys.map { $0 + "\n" }.joined(),
                        standardErrorLines: warnings + errorLines),
                    exitCode: errorLines.isEmpty ? .success : .error)
            }

            /// The key of a remove that succeeded.
            ///
            /// - Parameter removal: The outcome of one key.
            /// - Returns: The key, or `nil` when the key was not removed.
            private static func removedKey(of removal: SnapshotRemovalOutcome) -> String? {
                switch removal {
                case .removed(let sessionKey): sessionKey
                case .noSnapshotFolder, .failed: nil
                }
            }

            /// The stderr line of a key that was not removed.
            ///
            /// - Parameter removal: The outcome of one key.
            /// - Returns: The line, or `nil` when the key was removed.
            private static func errorLine(of removal: SnapshotRemovalOutcome) -> String? {
                switch removal {
                case .removed: nil
                case .noSnapshotFolder(let sessionKey): "\(sessionKey): \(noSnapshotFolderText)"
                case .failed(let sessionKey, let errorCase):
                    "The remove of the key \(sessionKey) failed (\(errorCase))."
                }
            }
        }
    }
}

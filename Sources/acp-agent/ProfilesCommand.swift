import ArgumentParser
import Foundation
import FoundationModelsACPAgent

/// A `profiles` subcommand that builds its report as a value, so a test reads
/// the report and never the process streams.
protocol ProfilesReporting {
  /// Runs the subcommand over the home that `environment` gives.
  ///
  /// - Parameter environment: The environment that the home of the CLI is
  ///   read from.
  /// - Returns: The report.
  /// - Throws: The error of the profile store.
  func report(environment: [String: String]) async throws -> CommandReport
}

extension ProfilesReporting {
  /// Runs the subcommand over the environment of the process and the
  /// `--home` option, and writes its report.
  ///
  /// - Parameter homeOptions: The `--home` option.
  /// - Throws: The error of the profile store.
  func run(homeOptions: HomeOptions) async throws {
    try await report(
      environment: homeOptions.environment(over: ProcessInfo.processInfo.environment)
    ).write()
  }
}

extension AcpAgentCommand {
  /// `acp-agent profiles`: list, show, save and delete the profile files.
  ///
  /// A profile is a file `profiles/<name>.yaml` of the project layer, of the
  /// user layer, or of the bundled profiles of the library; the first layer
  /// that has a name wins. The library ``ProfileStore`` does the work, thus
  /// the `models` endpoint and this command change the same files.
  struct Profiles: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "profiles",
      abstract: "List, show, save and delete the profile files.",
      subcommands: [List.self, Show.self, Save.self, Delete.self])

    /// The profile store of the CLI, over the settings folders of the home
    /// of the CLI.
    ///
    /// - Parameter environment: The environment that the home is read from.
    /// - Returns: The store. The call reads no file.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
    static func makeStore(environment: [String: String]) throws -> ProfileStore {
      ProfileStore(settingsFolders: try AgentComposition.settingsFolders(environment: environment))
    }

    /// The level that a save or a delete changes.
    ///
    /// - Parameters:
    ///   - project: Whether the change goes to the project layer.
    ///   - workingDirectory: The working directory of the project layer.
    /// - Returns: The level.
    static func level(project: Bool, workingDirectory: URL) -> SettingsLevel {
      project ? .session(workingDirectory) : .user
    }

    /// `profiles list`: one line for each profile, or one JSON array with
    /// `--json`.
    struct List: AsyncParsableCommand, ProfilesReporting {
      static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List each profile, with its layer.",
        discussion: """
          Each line has the name, the layer (project, user or bundled) and the path of \
          the file, separated by tabs. The first layer that has a name wins. A file \
          that does not decode goes to stderr.
          """)

      /// The separator between the fields of a line.
      private static let fieldSeparator = "\t"

      /// One profile of the `--json` listing.
      struct Row: Encodable {
        /// The name of the profile.
        let name: String

        /// The layer of the file.
        let layer: ProfileLayer

        /// The path of the file.
        let path: String

        /// The error of the file, or `nil` when it decodes.
        let error: String?
      }

      /// Whether the listing goes to stdout as JSON in place of lines.
      @Flag(name: .customLong("json"), help: "Write the listing to stdout as one JSON array.")
      var asJSON = false

      /// The `--cwd` option, which roots the project layer.
      @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

      /// The `--home` option, which roots the user layer.
      @OptionGroup var homeOptions: HomeOptions

      mutating func run() async throws {
        try await run(homeOptions: homeOptions)
      }

      func report(environment: [String: String]) async throws -> CommandReport {
        let entries = try Profiles.makeStore(environment: environment).layers
          .list(cwd: workingDirectoryOptions.directoryURL)
        let rows = entries.map {
          Row(name: $0.name, layer: $0.layer, path: $0.path, error: $0.error?.description)
        }
        return CommandReport(
          standardOutput: asJSON ? try JSONDocument.text(of: rows) : Self.lines(of: rows),
          standardErrorLines: rows.compactMap(\.error))
      }

      /// The text listing: one newline-terminated line for each row.
      ///
      /// - Parameter rows: The rows.
      /// - Returns: The lines.
      private static func lines(of rows: [Row]) -> String {
        rows.map { [$0.name, $0.layer.rawValue, $0.path].joined(separator: fieldSeparator) + "\n" }
          .joined()
      }
    }

    /// `profiles show <name>`: the profile as the text of a profile file.
    struct Show: AsyncParsableCommand, ProfilesReporting {
      static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print a profile as the text of a profile file.",
        discussion: """
          The text has each key of the profile: a key that its file leaves out has \
          the default of Router's profile definition.
          """)

      /// The name of the profile.
      @Argument(help: "The name of the profile.")
      var name: String

      /// The `--cwd` option, which roots the project layer.
      @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

      /// The `--home` option, which roots the user layer.
      @OptionGroup var homeOptions: HomeOptions

      mutating func run() async throws {
        try await run(homeOptions: homeOptions)
      }

      func report(environment: [String: String]) async throws -> CommandReport {
        let profile = try Profiles.makeStore(environment: environment).layers
          .read(name, cwd: workingDirectoryOptions.directoryURL)
        return CommandReport(
          standardOutput: try ProfileStore.text(of: profile), standardErrorLines: [])
      }
    }

    /// `profiles save <name> <file>`: check a profile file and save it.
    struct Save: AsyncParsableCommand, ProfilesReporting {
      static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Check a profile file and save it to a layer.",
        discussion: """
          The text of the file is saved as it is, after a decode checks it. The \
          change applies at the next launch of the agent.
          """)

      /// The name of the profile.
      @Argument(help: "The name of the profile: the name of its file.")
      var name: String

      /// The file whose text the command saves.
      @Argument(help: "The YAML file of the profile.")
      var file: String

      /// Whether the profile goes to the project layer.
      @Flag(name: .customLong("project"), help: "Save to the project layer of --cwd, not the user layer.")
      var project = false

      /// The `--cwd` option, which roots the project layer.
      @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

      /// The `--home` option, which roots the user layer.
      @OptionGroup var homeOptions: HomeOptions

      mutating func run() async throws {
        try await run(homeOptions: homeOptions)
      }

      func report(environment: [String: String]) async throws -> CommandReport {
        let text = try String(contentsOfFile: file, encoding: .utf8)
        try await Profiles.makeStore(environment: environment).save(
          text: text, as: name,
          level: Profiles.level(project: project, workingDirectory: workingDirectoryOptions.directoryURL))
        return CommandReport(standardOutput: "", standardErrorLines: [])
      }
    }

    /// `profiles delete <name>`: delete the file of a profile from a layer.
    struct Delete: AsyncParsableCommand, ProfilesReporting {
      static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete the file of a profile from a layer.",
        discussion: """
          A lower layer that has the name applies again. The bundled profiles are \
          read-only. The change applies at the next launch of the agent.
          """)

      /// The name of the profile.
      @Argument(help: "The name of the profile.")
      var name: String

      /// Whether the file is in the project layer.
      @Flag(
        name: .customLong("project"), help: "Delete from the project layer of --cwd, not the user layer.")
      var project = false

      /// The `--cwd` option, which roots the project layer.
      @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

      /// The `--home` option, which roots the user layer.
      @OptionGroup var homeOptions: HomeOptions

      mutating func run() async throws {
        try await run(homeOptions: homeOptions)
      }

      func report(environment: [String: String]) async throws -> CommandReport {
        try await Profiles.makeStore(environment: environment).delete(
          name,
          level: Profiles.level(project: project, workingDirectory: workingDirectoryOptions.directoryURL))
        return CommandReport(standardOutput: "", standardErrorLines: [])
      }
    }
  }
}

import ArgumentParser
import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `acp-agent config init` (cli-plan.md §5.11): a `config.yaml` with
/// every key at its default, written into one layer of the stack.
///
/// The command adds no generator and no writer. It calls
/// ``ConfigurationYAML``, which `/config export` also writes through,
/// and ``LayerFileWriter``, which `instructions eject` also writes
/// through. The last case of this suite proves the first half of that:
/// the two front doors write the same bytes to the same path.
///
/// Each test parses the real arguments and builds the report in process,
/// over a throwaway two-layer tree. No test touches the real home
/// directory, and no test writes to the process streams.
struct ConfigInitTests {
  // MARK: - Constants

  /// The flag that permits an overwrite. The refusal must name it.
  private static let forceFlag = "--force"

  /// The text that stands in for an edit a person makes after a write.
  private static let editedText = "# EDITED-CONFIG-TEXT\n"

  /// The bare name of the `/config` builtin slash command.
  private static let configCommandName = "config"

  /// The `/config` arguments that export to the user layer. The layer
  /// word comes from the mapping constant, so the test and the code
  /// spell the same word.
  private static let exportHomeArguments = "export \(LayerSelection.userLayerExportWord)"

  /// The value of a ``BuiltinCommandContext`` field that `/config
  /// export` reads nothing from. The command reads the configuration,
  /// the working directory and the user layer root, and no other
  /// field.
  private static let unreadContextField = ""

  // MARK: - Helpers

  /// Parses `config init` with `arguments` after the subcommand.
  ///
  /// - Parameter arguments: The options and flags after `init`.
  /// - Returns: The parsed command.
  /// - Throws: The parse error, or when the parse selects another
  ///   subcommand.
  private static func command(_ arguments: [String]) throws -> AcpAgentCommand.Config.Init {
    try #require(
      try AcpAgentCommand.parseAsRoot(["config", "init"] + arguments)
        as? AcpAgentCommand.Config.Init)
  }

  /// Writes into `fixture`'s tree and gives the report.
  ///
  /// - Parameters:
  ///   - fixture: The two-layer tree the file goes into.
  ///   - arguments: The flags after `init`. `--cwd` is added for the
  ///     fixture's workspace, so the caller states only the layer and
  ///     the force flag.
  /// - Returns: The report.
  /// - Throws: The parse error, or the write refusal.
  @discardableResult
  private static func initialize(
    in fixture: ConfigCommandFixture, arguments: [String] = []
  ) throws -> CommandReport {
    try command(["--cwd", fixture.workspace.path] + arguments)
      .report(environment: fixture.environment)
  }

  /// The loader the CLI composes over `fixture`'s stack.
  ///
  /// - Parameter fixture: The two-layer tree the loader reads.
  /// - Returns: The loader.
  /// - Throws: `DotfolderNameError`.
  private static func loader(in fixture: ConfigCommandFixture) throws -> ConfigurationLoader {
    try AgentComposition.makeConfigurationLoader(
      workingDirectory: fixture.workspace, environment: fixture.environment,
      fallbackProfileName: BundledProfiles.defaultName)
  }

  /// Loads `fixture`'s stack, over the same loader the CLI composes.
  ///
  /// - Parameter fixture: The two-layer tree to load.
  /// - Returns: The load result.
  /// - Throws: `DotfolderNameError`, or the configuration load error.
  private static func load(in fixture: ConfigCommandFixture) throws -> LoadedConfiguration {
    try loader(in: fixture).load()
  }

  /// The section schemas whose section the written file holds: each
  /// section that is not retired, except `profile`, which the file leaves
  /// out so the default by fit applies (decision D203).
  private static var writtenSectionSchemas: [(String, AgentConfiguration.SectionSchema)] {
    AgentConfiguration.sectionSchemas.filter { section, schema in
      schema != .retired && section != AgentConfiguration.CodingKeys.profile.stringValue
    }.map { ($0.key, $0.value) }
  }

  /// The keys one section schema states.
  ///
  /// - Parameter schema: The schema of one top-level section.
  /// - Returns: The checked keys, or the tool roster's own keys. A section
  ///   of named entries, such as `profiles`, states no key of its own: each
  ///   key is a name of the user.
  private static func knownKeys(of schema: AgentConfiguration.SectionSchema) -> Set<String> {
    switch schema {
    case .checked(let keys), .checkedWithRetired(let keys, _):
      return keys
    case .toolRoster:
      return ToolsConfiguration.knownKeys
    case .namedEntries, .scalar, .retired:
      return []
    }
  }

  /// Runs `/config export home` over `fixture`'s user layer, the way a
  /// session runs it.
  ///
  /// The context carries the builtin configuration of the CLI loader,
  /// because that is what `config init` writes: with the same value in
  /// both front doors, the bytes may be compared.
  ///
  /// - Parameter fixture: The two-layer tree the export writes into.
  /// - Throws: `DotfolderNameError`, or whatever the command streams.
  private static func exportHome(in fixture: ConfigCommandFixture) async throws {
    let context = BuiltinCommandContext(
      workingDirectory: fixture.workspace,
      configuration: try loader(in: fixture).builtinConfiguration,
      instructions: unreadContextField,
      modelName: unreadContextField,
      profileName: unreadContextField,
      dotfolderName: try DotfolderName(AgentComposition.dotfolderName),
      userLayerRoot: fixture.userDirectory)
    let command = try #require(
      BuiltinCommands.make(context: context).first { $0.name == configCommandName })
    let invocation = SlashCommand.Invocation(
      arguments: exportHomeArguments, workingDirectory: fixture.workspace)
    switch command.body {
    case .action(let body):
      for try await _ in body(invocation) {}
    case .prompt, .rendered:
      Issue.record("the \(configCommandName) builtin is not an action command")
    }
  }

  // MARK: - The flags (§5.11)

  /// The layer flags and the force flag parse, and `--project` is the
  /// default, which matches `instructions eject`.
  @Test func theLayerFlagsAndTheForceFlagParse() throws {
    let byDefault = try Self.command([])
    let user = try Self.command(["--user", Self.forceFlag])
    let project = try Self.command(["--project"])

    #expect(byDefault.layer == .project)
    #expect(!byDefault.overwrites)
    #expect(user.layer == .user)
    #expect(user.overwrites)
    #expect(project.layer == .project)
  }

  // MARK: - The written file

  /// The written file loads back to exactly the builtin configuration,
  /// with no warning, and the path it was written to goes to stdout.
  @Test func theWrittenFileLoadsBackToTheBuiltinConfiguration() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-round-trip")

    let report = try Self.initialize(in: fixture)

    let written = ConfigCommandFixture.configURL(in: fixture.projectDirectory)
    let loaded = try Self.load(in: fixture)
    #expect(loaded.configuration == (try Self.loader(in: fixture).builtinConfiguration))
    #expect(loaded.warnings.isEmpty)
    #expect(report.standardOutput == written.path + "\n")
    #expect(report.standardErrorLines.isEmpty)
  }

  /// The written file holds the same tool defaults as the builtin file,
  /// with the files exclude default of the CLI dotfolder.
  @Test func theWrittenToolsAreTheToolsOfTheBuiltinFile() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-builtin-file")
    try Self.initialize(in: fixture)
    let fileTools = try BuiltinConfigurationFile.root().decoded(as: AgentConfiguration.self).tools

    let loaded = try Self.load(in: fixture)

    #expect(
      loaded.configuration.tools
        == fileTools.resolvingDotfolderDefaults(
          try DotfolderName(AgentComposition.dotfolderName)))
  }

  /// The written file holds `tools.files.exclude` with its default: the
  /// dotfolder of the CLI, so a person sees the list and can edit it.
  @Test func theWrittenFileHoldsTheFilesExcludeDefault() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-files-exclude")
    try Self.initialize(in: fixture)

    let text = try textOnDisk(
      at: ConfigCommandFixture.configURL(in: fixture.projectDirectory))

    #expect(text.contains("    exclude:\n      - \".\(AgentComposition.dotfolderName)/\"\n"))
  }

  /// Every top-level section of the schema, and every key of every
  /// section, stands in the written file. A section the emitter does
  /// not carry fails this test.
  @Test func everySchemaSectionAndKeyStandsInTheWrittenFile() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-schema")
    try Self.initialize(in: fixture)

    let text = try textOnDisk(
      at: ConfigCommandFixture.configURL(in: fixture.projectDirectory))

    for (section, schema) in Self.writtenSectionSchemas {
      #expect(text.contains("\(section):"), "the section \(section) is not in the file")
      for key in Self.knownKeys(of: schema) {
        #expect(text.contains("\(key):"), "the key \(section).\(key) is not in the file")
      }
    }
  }

  /// Every key of the written file sits under a comment: the document
  /// opens with one, and each section carries one of its own.
  @Test func theWrittenFileCarriesACommentAboveEachSection() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-comments")
    try Self.initialize(in: fixture)

    let lines = try textOnDisk(
      at: ConfigCommandFixture.configURL(in: fixture.projectDirectory)
    ).split(separator: "\n").map(String.init)

    for (section, _) in Self.writtenSectionSchemas {
      let index = try #require(
        lines.firstIndex { $0.hasPrefix("\(section):") },
        "the section \(section) is not in the file")
      #expect(
        lines[lines.index(before: index)].hasPrefix("#"),
        "the section \(section) carries no comment")
    }
  }

  /// `--user` writes into the user layer, and leaves the project layer
  /// with no file.
  @Test func userWritesIntoTheUserLayer() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-user")

    let report = try Self.initialize(in: fixture, arguments: ["--user"])

    let written = ConfigCommandFixture.configURL(in: fixture.userDirectory)
    #expect(report.standardOutput == written.path + "\n")
    #expect(FileManager.default.fileExists(atPath: written.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: ConfigCommandFixture.configURL(in: fixture.projectDirectory).path))
  }

  /// `--cwd` selects which project layer receives the file: the named
  /// directory gets it, and the default one does not.
  @Test func cwdSelectsTheProjectLayerThatReceivesTheFile() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-cwd")
    let other = ConfigCommandFixture(label: "ConfigInitTests-cwd-other")

    let report = try Self.command(["--cwd", other.workspace.path])
      .report(environment: fixture.environment)

    let written = ConfigCommandFixture.configURL(in: other.projectDirectory)
    #expect(report.standardOutput == written.path + "\n")
    #expect(
      !FileManager.default.fileExists(
        atPath: ConfigCommandFixture.configURL(in: fixture.projectDirectory).path))
  }

  // MARK: - The profile (decision D203)

  /// The start of a line that sets the `profile` key.
  private static let profileKeyPrefix =
    "\(AgentConfiguration.CodingKeys.profile.stringValue):"

  /// A fit source where `medium` is the largest profile that fits.
  private static let mediumFits = ProfileFitStub(
    fitting: [BundledProfiles.mediumName, BundledProfiles.smallestName])

  /// The lines of `text` that set the `profile` key.
  ///
  /// - Parameter text: A `config.yaml` text.
  /// - Returns: The lines that start with the `profile` key.
  private static func profileKeyLines(in text: String) -> [Substring] {
    text.split(separator: "\n").filter { $0.hasPrefix(profileKeyPrefix) }
  }

  /// The loader the CLI composes over `fixture`'s stack, with the
  /// fallback profile that `fitSource` chooses.
  ///
  /// - Parameters:
  ///   - fixture: The two-layer tree the loader reads.
  ///   - fitSource: The fit source of the choice of the default profile.
  /// - Returns: The loader.
  /// - Throws: `DotfolderNameError`.
  private static func loader(
    in fixture: ConfigCommandFixture, fitSource: ProfileFitStub
  ) async throws -> ConfigurationLoader {
    try AgentComposition.makeConfigurationLoader(
      workingDirectory: fixture.workspace, environment: fixture.environment,
      fallbackProfileName: await AgentComposition.fallbackProfileName(
        workingDirectory: fixture.workspace, environment: fixture.environment,
        fitSource: fitSource))
  }

  /// The written file sets no `profile` key, so the default by fit
  /// applies.
  @Test func theWrittenFileSetsNoProfileKey() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-no-profile")
    try Self.initialize(in: fixture)

    let text = try textOnDisk(
      at: ConfigCommandFixture.configURL(in: fixture.projectDirectory))

    #expect(Self.profileKeyLines(in: text).isEmpty)
  }

  /// A load of the written file selects the profile that the fit source
  /// chooses.
  @Test func aLoadOfTheWrittenFileSelectsTheProfileOfTheFitSource() async throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-fit-load")
    try Self.initialize(in: fixture)

    let loaded = try await Self.loader(in: fixture, fitSource: Self.mediumFits).load()

    #expect(loaded.configuration.profile.name == BundledProfiles.mediumName)
  }

  /// The written file is the same text with two different fit sources, so
  /// it is the same on every Mac.
  @Test func theWrittenFileIsTheSameWithTwoFitSources() async throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-fit-same")
    let file = ConfigCommandFixture.configURL(in: fixture.projectDirectory)

    _ = try AcpAgentCommand.Config.writeDefaultConfiguration(
      into: .project, of: try await Self.loader(in: fixture, fitSource: .allFit),
      overwrites: false)
    let allFit = try textOnDisk(at: file)
    _ = try AcpAgentCommand.Config.writeDefaultConfiguration(
      into: .project, of: try await Self.loader(in: fixture, fitSource: .noneFit),
      overwrites: true)

    #expect(try textOnDisk(at: file) == allFit)
  }

  // MARK: - The overwrite guard

  /// A second `config init` without `--force` is refused: the message
  /// names the flag, the process exits 1 on stderr, and the file keeps
  /// its edit.
  @Test func aSecondInitWithoutForceRefusesAndChangesNoFile() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-refuse")
    try Self.initialize(in: fixture)
    let written = ConfigCommandFixture.configURL(in: fixture.projectDirectory)
    try Self.editedText.write(to: written, atomically: true, encoding: .utf8)

    let error = try #require(throws: LayerFileExistsError.self) {
      try Self.initialize(in: fixture)
    }

    #expect(AcpAgentCommand.fullMessage(for: error).contains(Self.forceFlag))
    #expect(
      AcpAgentCommand.exitOutcome(for: error)
        == AcpAgentCommand.ExitOutcome(
          code: ExitCode.failure.rawValue, writesToStandardError: true))
    #expect(try textOnDisk(at: written) == Self.editedText)
  }

  /// `--force` overwrites the edited file with the defaults.
  @Test func forceOverwritesTheWrittenFile() throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-force")
    try Self.initialize(in: fixture)
    let written = ConfigCommandFixture.configURL(in: fixture.projectDirectory)
    try Self.editedText.write(to: written, atomically: true, encoding: .utf8)

    let report = try Self.initialize(in: fixture, arguments: [Self.forceFlag])

    #expect(try textOnDisk(at: written) != Self.editedText)
    #expect(
      try Self.load(in: fixture).configuration == Self.loader(in: fixture).builtinConfiguration)
    #expect(report.standardOutput == written.path + "\n")
  }

  // MARK: - The two front doors

  /// The key lines of `text`, with no comment line and no `profile` key
  /// line.
  ///
  /// - Parameter text: A `config.yaml` text.
  /// - Returns: The lines, in order.
  private static func keyLinesWithoutProfile(in text: String) -> [Substring] {
    text.split(separator: "\n").filter {
      !$0.hasPrefix(commentPrefix) && !$0.hasPrefix(profileKeyPrefix)
    }
  }

  /// The start of a comment line.
  private static let commentPrefix = "#"

  /// `config init --user` and `/config export home` write the same keys
  /// with the same values to the same path: two front doors, one behavior
  /// (cli-plan.md §5.11). The one difference is the `profile` key:
  /// `config init` leaves it out, so the default by fit applies (decision
  /// D203), and `/config export` writes the profile of its session.
  ///
  /// `/config export` writes the session's effective configuration, so
  /// the comparable case is a session whose configuration is the
  /// builtin default — which is what `config init` always writes.
  @Test func initUserAndExportHomeWriteTheSameKeysToTheSamePath() async throws {
    let fixture = ConfigCommandFixture(label: "ConfigInitTests-two-doors")
    let file = ConfigCommandFixture.configURL(in: fixture.userDirectory)

    let report = try Self.initialize(in: fixture, arguments: ["--user"])
    let initialized = try textOnDisk(at: file)
    try await Self.exportHome(in: fixture)
    let exported = try textOnDisk(at: file)

    #expect(report.standardOutput == file.path + "\n")
    #expect(
      Self.keyLinesWithoutProfile(in: initialized) == Self.keyLinesWithoutProfile(in: exported))
    #expect(!initialized.isEmpty)
  }
}

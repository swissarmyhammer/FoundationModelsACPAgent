import ArgumentParser
import Foundation
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

    /// Loads `fixture`'s stack, over the same loader the CLI composes.
    ///
    /// - Parameter fixture: The two-layer tree to load.
    /// - Returns: The load result.
    /// - Throws: `DotfolderNameError`, or the configuration load error.
    private static func load(in fixture: ConfigCommandFixture) throws -> LoadedConfiguration {
        try AgentComposition.makeConfigurationLoader(
            workingDirectory: fixture.workspace, environment: fixture.environment
        ).load()
    }

    /// The keys one section schema states.
    ///
    /// - Parameter schema: The schema of one top-level section.
    /// - Returns: The checked keys, or the tool roster's own keys.
    private static func knownKeys(of schema: AgentConfiguration.SectionSchema) -> Set<String> {
        switch schema {
        case .checked(let keys):
            return keys
        case .toolRoster:
            return ToolsConfiguration.knownKeys
        }
    }

    /// Runs `/config export home` over `fixture`'s user layer, the way a
    /// session runs it.
    ///
    /// The context carries the builtin configuration, because that is
    /// what `config init` writes: with the same value in both front
    /// doors, the bytes may be compared.
    ///
    /// - Parameter fixture: The two-layer tree the export writes into.
    /// - Throws: `DotfolderNameError`, or whatever the command streams.
    private static func exportHome(in fixture: ConfigCommandFixture) async throws {
        let context = BuiltinCommandContext(
            workingDirectory: fixture.workspace,
            configuration: AgentConfiguration(),
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
        #expect(loaded.configuration == AgentConfiguration())
        #expect(loaded.warnings.isEmpty)
        #expect(report.standardOutput == written.path + "\n")
        #expect(report.standardErrorLines.isEmpty)
    }

    /// Every top-level section of the schema, and every key of every
    /// section, stands in the written file. A section the emitter does
    /// not carry fails this test.
    @Test func everySchemaSectionAndKeyStandsInTheWrittenFile() throws {
        let fixture = ConfigCommandFixture(label: "ConfigInitTests-schema")
        try Self.initialize(in: fixture)

        let text = try ConfigCommandFixture.text(
            at: ConfigCommandFixture.configURL(in: fixture.projectDirectory))

        for (section, schema) in AgentConfiguration.sectionSchemas {
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

        let lines = try ConfigCommandFixture.text(
            at: ConfigCommandFixture.configURL(in: fixture.projectDirectory)
        ).split(separator: "\n").map(String.init)

        for section in AgentConfiguration.sectionSchemas.keys {
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
        #expect(try ConfigCommandFixture.text(at: written) == Self.editedText)
    }

    /// `--force` overwrites the edited file with the defaults.
    @Test func forceOverwritesTheWrittenFile() throws {
        let fixture = ConfigCommandFixture(label: "ConfigInitTests-force")
        try Self.initialize(in: fixture)
        let written = ConfigCommandFixture.configURL(in: fixture.projectDirectory)
        try Self.editedText.write(to: written, atomically: true, encoding: .utf8)

        let report = try Self.initialize(in: fixture, arguments: [Self.forceFlag])

        #expect(try ConfigCommandFixture.text(at: written) != Self.editedText)
        #expect(try Self.load(in: fixture).configuration == AgentConfiguration())
        #expect(report.standardOutput == written.path + "\n")
    }

    // MARK: - The two front doors

    /// `config init --user` and `/config export home` write the same
    /// bytes to the same path: two front doors, one behavior
    /// (cli-plan.md §5.11).
    ///
    /// `/config export` writes the session's effective configuration, so
    /// the comparable case is a session whose configuration is the
    /// builtin default — which is what `config init` always writes.
    @Test func initUserAndExportHomeWriteTheSameBytesToTheSamePath() async throws {
        let fixture = ConfigCommandFixture(label: "ConfigInitTests-two-doors")
        let file = ConfigCommandFixture.configURL(in: fixture.userDirectory)

        let report = try Self.initialize(in: fixture, arguments: ["--user"])
        let initialized = try ConfigCommandFixture.text(at: file)
        try await Self.exportHome(in: fixture)
        let exported = try ConfigCommandFixture.text(at: file)

        #expect(report.standardOutput == file.path + "\n")
        #expect(initialized == exported)
        #expect(!initialized.isEmpty)
    }
}

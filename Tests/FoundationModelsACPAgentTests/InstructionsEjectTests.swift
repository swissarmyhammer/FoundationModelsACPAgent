import ArgumentParser
import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `acp-agent instructions eject` (cli-plan.md §5.3, plan.md §3.1): the
/// compiled-in `Instructions.md` written into one layer, so a person can
/// read and edit the prompt that a layer file replaces wholesale.
///
/// Each test parses the real arguments and builds the report in process,
/// over a throwaway two-layer tree. No test touches the real home
/// directory, and no test writes to the process streams.
struct InstructionsEjectTests {
    // MARK: - Constants

    /// The text that stands in for an edit a person makes after an eject.
    private static let editedText = "EDITED-PROMPT-TEXT"

    /// The flag that permits an overwrite. The refusal must name it.
    private static let forceFlag = "--force"

    // MARK: - Helpers

    /// Parses `instructions eject` with `arguments` after the subcommand.
    ///
    /// - Parameter arguments: The options and flags after `eject`.
    /// - Returns: The parsed command.
    /// - Throws: The parse error, or when the parse selects another
    ///   subcommand.
    private static func command(_ arguments: [String]) throws
        -> AcpAgentCommand.Instructions.Eject
    {
        try #require(
            try AcpAgentCommand.parseAsRoot(["instructions", "eject"] + arguments)
                as? AcpAgentCommand.Instructions.Eject)
    }

    /// Ejects into `fixture`'s tree and gives the report.
    ///
    /// - Parameters:
    ///   - fixture: The two-layer tree the file goes into.
    ///   - arguments: The flags after `eject`. `--cwd` is added for the
    ///     fixture's workspace, so the caller states only the layer and
    ///     the force flag.
    ///   - workspace: The directory `--cwd` names. Defaults to the
    ///     fixture's own workspace.
    /// - Returns: The report.
    /// - Throws: The parse error, or the write refusal.
    @discardableResult
    private static func eject(
        in fixture: ConfigCommandFixture, arguments: [String] = [], workspace: URL? = nil
    ) throws -> CommandReport {
        let directory = workspace ?? fixture.workspace
        return try command(["--cwd", directory.path] + arguments)
            .report(environment: fixture.environment)
    }

    /// The assembler of a session rooted at `fixture`'s workspace, over the
    /// same stack the CLI composes.
    ///
    /// - Parameter fixture: The two-layer tree the stack roots at.
    /// - Returns: The assembler.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
    private static func assembler(in fixture: ConfigCommandFixture) throws
        -> InstructionsAssembler
    {
        let stack = try AgentComposition.makeConfigurationLoader(
            workingDirectory: fixture.workspace, environment: fixture.environment
        ).stack
        return InstructionsAssembler(stack: stack, workingDirectory: fixture.workspace)
    }

    /// The `Instructions.md` path inside `directory`.
    ///
    /// - Parameter directory: The layer root.
    /// - Returns: The file URL.
    private static func instructionsURL(in directory: URL) -> URL {
        directory.appendingPathComponent(InstructionsAssembler.instructionsFileName)
    }

    /// The text of the file at `url`.
    ///
    /// - Parameter url: The file to read.
    /// - Returns: The content as UTF-8 text.
    /// - Throws: The read error.
    private static func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The flags (§5.3)

    /// The layer flags and the force flag parse, and `--project` is the
    /// default, which matches `config init`.
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

    /// The ejected file is byte-equal to the compiled-in floor, and the
    /// path it was written to goes to stdout with nothing on stderr.
    @Test func theEjectedFileIsByteEqualToTheBuiltinFloor() throws {
        let fixture = ConfigCommandFixture(label: "InstructionsEjectTests-floor")

        let report = try Self.eject(in: fixture)

        let written = Self.instructionsURL(in: fixture.projectDirectory)
        #expect(try Self.text(at: written) == BuiltinInstructions.text)
        #expect(report.standardOutput == written.path + "\n")
        #expect(report.standardErrorLines.isEmpty)
    }

    /// `--user` writes into the user layer, and leaves the project layer
    /// with no file.
    @Test func userWritesIntoTheUserLayer() throws {
        let fixture = ConfigCommandFixture(label: "InstructionsEjectTests-user")

        let report = try Self.eject(in: fixture, arguments: ["--user"])

        let written = Self.instructionsURL(in: fixture.userDirectory)
        #expect(try Self.text(at: written) == BuiltinInstructions.text)
        #expect(report.standardOutput == written.path + "\n")
        #expect(
            !FileManager.default.fileExists(
                atPath: Self.instructionsURL(in: fixture.projectDirectory).path))
    }

    /// `--cwd` selects which project layer receives the file: the named
    /// directory gets it, and the default one does not.
    @Test func cwdSelectsTheProjectLayerThatReceivesTheFile() throws {
        let fixture = ConfigCommandFixture(label: "InstructionsEjectTests-cwd")
        let other = ConfigCommandFixture(label: "InstructionsEjectTests-cwd-other")

        let report = try Self.eject(in: fixture, workspace: other.workspace)

        let written = Self.instructionsURL(in: other.projectDirectory)
        #expect(try Self.text(at: written) == BuiltinInstructions.text)
        #expect(report.standardOutput == written.path + "\n")
        #expect(
            !FileManager.default.fileExists(
                atPath: Self.instructionsURL(in: fixture.projectDirectory).path))
    }

    // MARK: - What the assembler then reads

    /// After an eject the assembler reads the written file in place of the
    /// compiled-in text: the body is the same bytes, and the path header
    /// says the text now comes from disk.
    @Test func theAssemblerReadsTheEjectedFileInPlaceOfTheFloor() async throws {
        let fixture = ConfigCommandFixture(label: "InstructionsEjectTests-assembler")
        let assembler = try Self.assembler(in: fixture)
        let before = try await assembler.assemble().text
        #expect(before == BuiltinInstructions.text)

        try Self.eject(in: fixture)

        let after = try await assembler.assemble().text
        let written = Self.instructionsURL(in: fixture.projectDirectory)
        #expect(after.hasSuffix(BuiltinInstructions.text))
        #expect(after.contains(written.path))
        #expect(after != before)
    }

    /// An edit to the ejected file becomes the whole prompt: the file
    /// replaces the floor wholesale, and no line of the floor survives.
    @Test func anEditToTheEjectedFileBecomesTheWholePrompt() async throws {
        let fixture = ConfigCommandFixture(label: "InstructionsEjectTests-edit")
        try Self.eject(in: fixture)
        let written = Self.instructionsURL(in: fixture.projectDirectory)
        try Self.editedText.write(to: written, atomically: true, encoding: .utf8)

        let assembled = try await Self.assembler(in: fixture).assemble().text

        #expect(assembled.contains(Self.editedText))
        #expect(!assembled.contains(BuiltinInstructions.text))
    }

    // MARK: - The overwrite guard

    /// A second eject without `--force` is refused: the message names the
    /// flag, the process exits 1 on stderr, and the file keeps its edit.
    @Test func aSecondEjectWithoutForceRefusesAndChangesNoFile() throws {
        let fixture = ConfigCommandFixture(label: "InstructionsEjectTests-refuse")
        try Self.eject(in: fixture)
        let written = Self.instructionsURL(in: fixture.projectDirectory)
        try Self.editedText.write(to: written, atomically: true, encoding: .utf8)

        let error = try #require(throws: LayerFileExistsError.self) {
            try Self.eject(in: fixture)
        }

        #expect(AcpAgentCommand.fullMessage(for: error).contains(Self.forceFlag))
        #expect(
            AcpAgentCommand.exitOutcome(for: error)
                == AcpAgentCommand.ExitOutcome(
                    code: ExitCode.failure.rawValue, writesToStandardError: true))
        #expect(try Self.text(at: written) == Self.editedText)
    }

    /// `--force` overwrites the edited file with the compiled-in floor.
    @Test func forceOverwritesTheEjectedFile() throws {
        let fixture = ConfigCommandFixture(label: "InstructionsEjectTests-force")
        try Self.eject(in: fixture)
        let written = Self.instructionsURL(in: fixture.projectDirectory)
        try Self.editedText.write(to: written, atomically: true, encoding: .utf8)

        let report = try Self.eject(in: fixture, arguments: [Self.forceFlag])

        #expect(try Self.text(at: written) == BuiltinInstructions.text)
        #expect(report.standardOutput == written.path + "\n")
    }

    // MARK: - The layer the stack does not hold

    /// A stack with no layer of the selected kind is refused, and the
    /// message names the layer.
    @Test func aStackWithoutTheSelectedLayerIsRefused() throws {
        let fixture = ConfigCommandFixture(label: "InstructionsEjectTests-nolayer")
        var stack = try AgentComposition.makeConfigurationLoader(
            workingDirectory: fixture.workspace, environment: fixture.environment
        ).stack
        stack.layers = []

        let error = try #require(throws: LayerMissingError.self) {
            try LayerFileWriter.write(
                BuiltinInstructions.text,
                named: InstructionsAssembler.instructionsFileName,
                into: .project, of: stack, overwrites: false)
        }

        #expect(error.description.contains(LayerSelection.project.rawValue))
    }
}

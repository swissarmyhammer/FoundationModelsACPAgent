import ArgumentParser
import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `acp-agent config edit` (cli-plan.md §5.11): the nearest `config.yaml`
/// opened in `$EDITOR`, the defaults written first when no layer holds
/// one, and a refusal that names the variable when no editor is set.
///
/// **No test opens an interactive editor, and no test waits for a
/// person.** The editor command is a process fact, so it comes out of
/// the environment dictionary each case injects, the way every other
/// process fact of this CLI does. The case that runs the editor for real
/// injects a small script that writes the file and ends at once, which
/// also proves the launcher handed the file path over.
struct ConfigEditTests {
    // MARK: - Constants

    /// The text the injected editor writes into the file it is given. A
    /// test reads it back to prove the editor received the path.
    private static let editorOutput = "# WRITTEN-BY-THE-INJECTED-EDITOR"

    /// The name of the injected editor script.
    private static let editorScriptName = "injected-editor.sh"

    /// The permissions of the injected editor script: the owner writes,
    /// and everybody reads and runs.
    private static let executablePermissions: NSNumber = 0o755

    /// An editor command that always ends with a failure status and
    /// changes no file.
    private static let failingEditorCommand = "/usr/bin/false"

    /// A project `config.yaml` that sets one key, so a case can say
    /// WHICH file the plan chose.
    private static let projectYAML = "recording:\n  level: off\n"

    /// A user `config.yaml` that sets one key, so a case can say WHICH
    /// file the plan chose.
    private static let userYAML = "transcripts:\n  location: home\n"

    // MARK: - Helpers

    /// Parses `config edit` over `fixture`'s workspace.
    ///
    /// - Parameter fixture: The two-layer tree the stack roots at.
    /// - Returns: The parsed command.
    /// - Throws: The parse error, or when the parse selects another
    ///   subcommand.
    private static func command(in fixture: ConfigCommandFixture) throws
        -> AcpAgentCommand.Config.Edit
    {
        try #require(
            try AcpAgentCommand.parseAsRoot(["config", "edit", "--cwd", fixture.workspace.path])
                as? AcpAgentCommand.Config.Edit)
    }

    /// The plan of one `config edit` over `fixture`, with `editor` as the
    /// injected `$EDITOR`.
    ///
    /// - Parameters:
    ///   - fixture: The two-layer tree the stack roots at.
    ///   - editor: The editor command to inject, or `nil` to set no
    ///     variable at all.
    /// - Returns: The plan.
    /// - Throws: The parse error, the refusal that no editor is named, or
    ///   the write error of the defaults.
    private static func plan(
        in fixture: ConfigCommandFixture, editor: String?
    ) throws -> AcpAgentCommand.Config.Edit.Plan {
        var environment = fixture.environment
        environment[EditorLauncher.variable] = editor
        return try command(in: fixture).plan(environment: environment)
    }

    /// Writes an editor script into `fixture`'s workspace and gives the
    /// command that runs it.
    ///
    /// The script writes ``editorOutput`` into the file it is given and
    /// ends at once, so it stands in for an editor without ever waiting
    /// for a person.
    ///
    /// - Parameter fixture: The tree the script is written into.
    /// - Returns: The editor command.
    /// - Throws: The write error, or the permission-setting error.
    private static func makeEditorCommand(in fixture: ConfigCommandFixture) throws -> String {
        let script = fixture.workspace.appendingPathComponent(editorScriptName)
        try """
            #!/bin/sh
            printf '%s' '\(editorOutput)' > "$1"
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executablePermissions], ofItemAtPath: script.path)
        return script.path
    }

    /// Whether a `config.yaml` stands in `directory`.
    ///
    /// - Parameter directory: The layer root.
    /// - Returns: `true` when the file is on disk.
    private static func hasConfigFile(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: ConfigCommandFixture.configURL(in: directory).path)
    }

    // MARK: - No editor

    /// With no `$EDITOR` the command exits 1, the message names the
    /// variable, and no file is written.
    @Test func withNoEditorTheCommandRefusesAndNamesTheVariable() throws {
        let fixture = ConfigCommandFixture(label: "ConfigEditTests-no-editor")

        let error = try #require(throws: EditorNotNamedError.self) {
            try Self.plan(in: fixture, editor: nil)
        }

        #expect(AcpAgentCommand.fullMessage(for: error).contains(EditorLauncher.variable))
        #expect(
            AcpAgentCommand.exitOutcome(for: error)
                == AcpAgentCommand.ExitOutcome(
                    code: ExitCode.failure.rawValue, writesToStandardError: true))
        #expect(!Self.hasConfigFile(in: fixture.projectDirectory))
        #expect(!Self.hasConfigFile(in: fixture.userDirectory))
    }

    /// An `$EDITOR` that holds only spaces names no editor either.
    @Test func anEmptyEditorValueNamesNoEditor() throws {
        let fixture = ConfigCommandFixture(label: "ConfigEditTests-blank-editor")

        #expect(throws: EditorNotNamedError.self) {
            try Self.plan(in: fixture, editor: "   ")
        }
    }

    // MARK: - The file the plan chooses

    /// With no `config.yaml` in any layer the command writes the
    /// defaults into the project layer first, and says so on stderr.
    /// stdout stays empty, because the editor owns the terminal.
    @Test func withNoFileTheDefaultsAreWrittenFirstAndSaidOnStderr() throws {
        let fixture = ConfigCommandFixture(label: "ConfigEditTests-write-first")

        let plan = try Self.plan(in: fixture, editor: Self.failingEditorCommand)

        let written = ConfigCommandFixture.configURL(in: fixture.projectDirectory)
        #expect(plan.file == written)
        #expect(plan.report.standardErrorLines.count == 1)
        #expect(plan.report.standardErrorLines.first?.contains(written.path) == true)
        #expect(plan.report.standardOutput.isEmpty)
        #expect(
            try AgentComposition.makeConfigurationLoader(
                workingDirectory: fixture.workspace, environment: fixture.environment
            ).load().configuration == AgentConfiguration())
    }

    /// The nearest file wins: with a file in both layers the plan opens
    /// the project one, and says nothing on stderr.
    @Test func theNearestFileIsTheProjectOne() throws {
        let fixture = ConfigCommandFixture(label: "ConfigEditTests-nearest")
        try fixture.writeUserConfig(Self.userYAML)
        try fixture.writeProjectConfig(Self.projectYAML)

        let plan = try Self.plan(in: fixture, editor: Self.failingEditorCommand)

        #expect(plan.file == ConfigCommandFixture.configURL(in: fixture.projectDirectory))
        #expect(plan.report.standardErrorLines.isEmpty)
        #expect(try textOnDisk(at: plan.file) == Self.projectYAML)
    }

    /// With a file in the user layer alone the plan opens that one, and
    /// writes nothing into the project layer.
    @Test func withOnlyAUserFileThatOneIsOpened() throws {
        let fixture = ConfigCommandFixture(label: "ConfigEditTests-user-only")
        try fixture.writeUserConfig(Self.userYAML)

        let plan = try Self.plan(in: fixture, editor: Self.failingEditorCommand)

        #expect(plan.file == ConfigCommandFixture.configURL(in: fixture.userDirectory))
        #expect(plan.report.standardErrorLines.isEmpty)
        #expect(!Self.hasConfigFile(in: fixture.projectDirectory))
    }

    // MARK: - The editor the launcher runs

    /// The editor receives the path of the file the plan chose: the
    /// injected editor writes its mark into that file, and the file
    /// holds it afterwards.
    @Test func theEditorReceivesThePathOfTheChosenFile() throws {
        let fixture = ConfigCommandFixture(label: "ConfigEditTests-launch")
        try fixture.writeProjectConfig(Self.projectYAML)
        let editor = try Self.makeEditorCommand(in: fixture)

        let plan = try Self.plan(in: fixture, editor: editor)
        try EditorLauncher.open(plan.file, with: plan.editorCommand)

        #expect(try textOnDisk(at: plan.file) == Self.editorOutput)
    }

    /// An editor that ends with a failure status is reported, and the
    /// message names the command and the status.
    @Test func anEditorThatFailsIsReported() throws {
        let fixture = ConfigCommandFixture(label: "ConfigEditTests-failure")
        try fixture.writeProjectConfig(Self.projectYAML)
        let plan = try Self.plan(in: fixture, editor: Self.failingEditorCommand)

        let error = try #require(throws: EditorFailedError.self) {
            try EditorLauncher.open(plan.file, with: plan.editorCommand)
        }

        #expect(error.command == Self.failingEditorCommand)
        #expect(error.status != 0)
        #expect(AcpAgentCommand.fullMessage(for: error).contains(Self.failingEditorCommand))
    }

    // MARK: - The parse

    /// `config edit` parses, and carries the `--cwd` option.
    @Test func theCommandParsesAndCarriesCwd() throws {
        let fixture = ConfigCommandFixture(label: "ConfigEditTests-parse")

        let edit = try Self.command(in: fixture)

        #expect(edit.workingDirectoryOptions.workingDirectory == fixture.workspace.path)
    }
}

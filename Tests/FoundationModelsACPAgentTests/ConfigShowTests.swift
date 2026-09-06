import ArgumentParser
import Foundation
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `acp-agent config show` (cli-plan.md §5.11): the merged configuration
/// as YAML on stdout, the per-key layer under `--source`, the same tree
/// as JSON under `--json`, `--cwd`, and the warnings on stderr. Each test
/// parses the real arguments and builds the report in process.
struct ConfigShowTests {
    // MARK: - Constants

    /// The suffix the annotation of a key no layer set carries.
    private static let builtinAnnotation = "# builtin"

    /// A project `config.yaml` that sets one key.
    private static let recordingOffYAML = "recording:\n  level: off\n"

    /// The number of keys ``recordingOffYAML`` sets: the section key, and
    /// the value key under it.
    private static let recordingOffKeyCount = 2

    /// The `compaction.trigger` a fixture sets; it differs from the
    /// default so the value is observable in both output forms.
    private static let configuredTrigger = 0.7

    /// A project `config.yaml` that sets `compaction.trigger`.
    private static let triggerYAML = "compaction:\n  trigger: \(configuredTrigger)\n"

    /// A project `config.yaml` with an unknown section, which the loader
    /// reports as a warning.
    private static let permissionsYAML = "permissions:\n  allow: []\n"

    /// The document `--json --source` writes.
    private struct AnnotatedDocument: Decodable {
        let configuration: AgentConfiguration
        let sources: [String: String]
    }

    // MARK: - Helpers

    /// Parses `config show` with `arguments` and builds its report over
    /// `fixture`'s environment.
    ///
    /// - Parameters:
    ///   - arguments: The arguments after `config show`.
    ///   - fixture: The two-layer tree the report reads.
    /// - Returns: The report.
    /// - Throws: The parse or load error.
    private static func report(
        _ arguments: [String], in fixture: ConfigCommandFixture
    ) throws -> CommandReport {
        let show = try #require(
            try AcpAgentCommand.parseAsRoot(
                ["config", "show", "--cwd", fixture.workspace.path] + arguments)
                as? AcpAgentCommand.Config.Show)
        return try show.report(environment: fixture.environment)
    }

    /// The lines of `text` that carry a mapping key: not a comment, not a
    /// sequence item, and not blank.
    private static func keyLines(in text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("-")
        }
    }

    // MARK: - The merged tree

    /// With no file in any layer the report is the builtin configuration,
    /// on stdout, with nothing on stderr.
    @Test func noFilesShowTheBuiltinConfiguration() throws {
        let fixture = ConfigCommandFixture(label: "ConfigShowTests-builtin")

        let report = try Self.report([], in: fixture)

        #expect(report.standardOutput.contains("profile:"))
        #expect(report.standardOutput.contains("recording:"))
        #expect(report.standardOutput.contains("level: \"full\""))
        #expect(report.standardErrorLines.isEmpty)
    }

    /// The report is the merged configuration: a project key shows its
    /// value, not the default.
    @Test func aProjectKeyShowsItsMergedValue() throws {
        let fixture = ConfigCommandFixture(label: "ConfigShowTests-merged")
        try fixture.writeProjectConfig(Self.recordingOffYAML)

        let report = try Self.report([], in: fixture)

        #expect(report.standardOutput.contains("level: \"off\""))
        #expect(!report.standardOutput.contains("level: \"full\""))
    }

    /// `--cwd` selects the project layer: two workspaces with different
    /// files give different reports.
    @Test func cwdSelectsTheProjectLayer() throws {
        let first = ConfigCommandFixture(label: "ConfigShowTests-cwd-first")
        let second = ConfigCommandFixture(label: "ConfigShowTests-cwd-second")
        try first.writeProjectConfig(Self.recordingOffYAML)
        try second.writeProjectConfig(Self.triggerYAML)

        let firstReport = try Self.report([], in: first)
        let secondReport = try Self.report([], in: second)

        #expect(firstReport.standardOutput.contains("level: \"off\""))
        #expect(!firstReport.standardOutput.contains("trigger: \(Self.configuredTrigger)"))
        #expect(secondReport.standardOutput.contains("trigger: \(Self.configuredTrigger)"))
        #expect(secondReport.standardOutput.contains("level: \"full\""))
    }

    // MARK: - --source

    /// With no file in any layer, every key reports `builtin`.
    @Test func withNoFileEveryKeyReportsBuiltin() throws {
        let fixture = ConfigCommandFixture(label: "ConfigShowTests-source-builtin")

        let report = try Self.report(["--source"], in: fixture)

        let keyLines = Self.keyLines(in: report.standardOutput)
        #expect(!keyLines.isEmpty)
        #expect(keyLines.allSatisfy { $0.hasSuffix(Self.builtinAnnotation) })
    }

    /// With a project file that sets one key, that key reports `project`
    /// and the others `builtin`. The section the key sits in reports
    /// `project` too: the project layer introduced it.
    @Test func aProjectKeyReportsProjectAndTheOthersBuiltin() throws {
        let fixture = ConfigCommandFixture(label: "ConfigShowTests-source-project")
        try fixture.writeProjectConfig(Self.recordingOffYAML)

        let report = try Self.report(["--source"], in: fixture)

        let keyLines = Self.keyLines(in: report.standardOutput)
        let projectLines = keyLines.filter { $0.hasSuffix("# project") }
        let builtinLines = keyLines.filter { $0.hasSuffix(Self.builtinAnnotation) }
        #expect(projectLines.count == Self.recordingOffKeyCount)
        #expect(projectLines.contains { $0.hasPrefix("recording:") })
        #expect(projectLines.contains { $0.contains("level: \"off\"") })
        #expect(builtinLines.count == keyLines.count - Self.recordingOffKeyCount)
        #expect(!report.standardOutput.contains("# user"))
    }

    /// A user key reports `user`, and a project key that overrides a user
    /// key reports `project`.
    @Test func aUserKeyReportsUserAndAnOverrideReportsProject() throws {
        let fixture = ConfigCommandFixture(label: "ConfigShowTests-source-user")
        try fixture.writeUserConfig("recording:\n  level: off\ntranscripts:\n  location: home\n")
        try fixture.writeProjectConfig("recording:\n  level: full\n")

        let report = try Self.report(["--source"], in: fixture)

        let keyLines = Self.keyLines(in: report.standardOutput)
        #expect(keyLines.contains { $0.contains("level: \"full\"") && $0.hasSuffix("# project") })
        #expect(keyLines.contains { $0.contains("location: \"home\"") && $0.hasSuffix("# user") })
    }

    /// Without `--source` no key carries an annotation.
    @Test func withoutSourceNoKeyIsAnnotated() throws {
        let fixture = ConfigCommandFixture(label: "ConfigShowTests-no-source")
        try fixture.writeProjectConfig(Self.recordingOffYAML)

        let report = try Self.report([], in: fixture)

        #expect(!report.standardOutput.contains("# project"))
        #expect(!report.standardOutput.contains(Self.builtinAnnotation))
    }

    // MARK: - --json

    /// `--json` parses as JSON and holds the same values as the YAML
    /// output: the JSON decodes to the configuration the YAML reloads to.
    @Test func jsonDecodesToTheSameValuesAsTheYAML() throws {
        let fixture = ConfigCommandFixture(label: "ConfigShowTests-json")
        try fixture.writeProjectConfig(Self.triggerYAML)
        let reloadFixture = ConfigCommandFixture(label: "ConfigShowTests-json-reload")

        let jsonReport = try Self.report(["--json"], in: fixture)
        let yamlReport = try Self.report([], in: fixture)

        let decoded = try JSONDecoder().decode(
            AgentConfiguration.self, from: Data(jsonReport.standardOutput.utf8))
        try reloadFixture.writeProjectConfig(yamlReport.standardOutput)
        let reloaded = try ConfigurationLoader(
            name: DotfolderName(AgentComposition.dotfolderName),
            workingDirectory: reloadFixture.workspace,
            environment: reloadFixture.environment
        ).load()
        #expect(decoded == reloaded.configuration)
        #expect(decoded.compaction.trigger == Self.configuredTrigger)
        #expect(jsonReport.standardErrorLines.isEmpty)
    }

    /// `--json --source` holds the tree under `configuration` and the
    /// layer of every key under `sources`.
    @Test func jsonWithSourceHoldsTheTreeAndTheSources() throws {
        let fixture = ConfigCommandFixture(label: "ConfigShowTests-json-source")
        try fixture.writeProjectConfig(Self.recordingOffYAML)

        let report = try Self.report(["--json", "--source"], in: fixture)

        let document = try JSONDecoder().decode(
            AnnotatedDocument.self, from: Data(report.standardOutput.utf8))
        #expect(document.configuration.recording.level == .off)
        #expect(document.sources["recording.level"] == "project")
        #expect(document.sources["recording"] == "project")
        #expect(document.sources["compaction.trigger"] == "builtin")
        #expect(document.sources["tools.shell"] == "builtin")
    }

    // MARK: - stderr

    /// A configuration warning goes to stderr, and never to stdout.
    @Test func aWarningGoesToStderrAndNeverToStdout() throws {
        let fixture = ConfigCommandFixture(label: "ConfigShowTests-warning")
        try fixture.writeProjectConfig(Self.permissionsYAML)

        let report = try Self.report([], in: fixture)

        #expect(report.standardErrorLines.count == 1)
        #expect(report.standardErrorLines.first?.contains("permissions") == true)
        #expect(!report.standardOutput.contains("permissions"))
        #expect(report.standardOutput.contains("profile:"))
    }

    // MARK: - The parse

    /// The flags parse onto `Show`, and default off.
    @Test func theFlagsParseAndDefaultOff() throws {
        let bare = try #require(
            try AcpAgentCommand.parseAsRoot(["config", "show"]) as? AcpAgentCommand.Config.Show)
        let flagged = try #require(
            try AcpAgentCommand.parseAsRoot(["config", "show", "--source", "--json"])
                as? AcpAgentCommand.Config.Show)

        #expect(!bare.annotatesSource)
        #expect(!bare.asJSON)
        #expect(bare.workingDirectoryOptions.workingDirectory == nil)
        #expect(flagged.annotatesSource)
        #expect(flagged.asJSON)
    }
}

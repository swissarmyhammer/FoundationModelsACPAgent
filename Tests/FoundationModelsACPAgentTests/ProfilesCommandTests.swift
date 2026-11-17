import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// `acp-agent profiles list|show|save|delete`: the profile files over the
/// profile store, with the layers of the CLI.
@Suite struct ProfilesCommandTests {
  /// The text of a profile file that names one `standard` model.
  private static let customText = "standard:\n  - mlx-community/Qwen3-4B-4bit\n"

  /// Parses a `profiles` subcommand and runs it.
  ///
  /// - Parameters:
  ///   - arguments: The arguments after `profiles`.
  ///   - fixture: The two-layer tree.
  /// - Returns: The report.
  /// - Throws: The parse error, or the error of the command.
  private static func report(_ arguments: [String], in fixture: ConfigCommandFixture) async throws
    -> CommandReport
  {
    let command = try #require(
      try AcpAgentCommand.parseAsRoot(["profiles"] + arguments) as? any ProfilesReporting)
    return try await command.report(environment: fixture.environment)
  }

  /// Writes a profile text to a file of the workspace, for `save`.
  ///
  /// - Parameter fixture: The two-layer tree.
  /// - Returns: The path of the file.
  private static func writeSource(in fixture: ConfigCommandFixture) throws -> String {
    let file = fixture.workspace.appendingPathComponent("custom-source.yaml")
    try customText.write(to: file, atomically: true, encoding: .utf8)
    return file.path
  }

  /// With no file, `list` gives the bundled profiles.
  @Test func listGivesTheBundledProfiles() async throws {
    let fixture = ConfigCommandFixture(label: "ProfilesCommandTests-list")

    let report = try await Self.report(["list", "--cwd", fixture.workspace.path], in: fixture)

    let lines = report.standardOutput.split(separator: "\n").map { $0.split(separator: "\t") }
    #expect(lines.map { $0.prefix(2).joined(separator: " ") } == ["large bundled", "small bundled"])
  }

  /// `save` writes the user file, and `list` then names its layer.
  @Test func saveWritesTheUserFile() async throws {
    let fixture = ConfigCommandFixture(label: "ProfilesCommandTests-save")
    let source = try Self.writeSource(in: fixture)

    _ = try await Self.report(["save", "custom", source], in: fixture)

    let file = fixture.userDirectory.appendingPathComponent("profiles/custom.yaml")
    #expect(try String(contentsOf: file, encoding: .utf8) == Self.customText)
  }

  /// `save --project` writes the project file.
  @Test func saveProjectWritesTheProjectFile() async throws {
    let fixture = ConfigCommandFixture(label: "ProfilesCommandTests-save-project")
    let source = try Self.writeSource(in: fixture)

    _ = try await Self.report(
      ["save", "custom", source, "--project", "--cwd", fixture.workspace.path], in: fixture)

    let file = fixture.projectDirectory.appendingPathComponent("profiles/custom.yaml")
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  /// `show` prints the profile as the text of a profile file.
  @Test func showPrintsTheProfile() async throws {
    let fixture = ConfigCommandFixture(label: "ProfilesCommandTests-show")

    let report = try await Self.report(["show", "small"], in: fixture)

    #expect(report.standardOutput.contains("mlx-community/Qwen3.8-27B-4bit"))
  }

  /// `show` of a name that no layer has fails, and names the profiles.
  @Test func showOfAnUnknownNameFails() async throws {
    let fixture = ConfigCommandFixture(label: "ProfilesCommandTests-show-unknown")

    await #expect(throws: ProfileStoreError.unknownProfile(name: "huge", available: ["large", "small"])) {
      try await Self.report(["show", "huge"], in: fixture)
    }
  }

  /// `delete` removes the user file.
  @Test func deleteRemovesTheUserFile() async throws {
    let fixture = ConfigCommandFixture(label: "ProfilesCommandTests-delete")
    let source = try Self.writeSource(in: fixture)
    _ = try await Self.report(["save", "custom", source], in: fixture)

    _ = try await Self.report(["delete", "custom"], in: fixture)

    let file = fixture.userDirectory.appendingPathComponent("profiles/custom.yaml")
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }
}

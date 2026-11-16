import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The `statusline` section (ACPA-22, D194): the agent keeps the value of
/// the status line of AgentViewKit, checks its keys at two levels, and the
/// `settings` endpoint reads and changes it.
@Suite struct StatusLineSettingTests {
  /// The key path of the preset.
  private static let presetKeyPath = [
    AgentConfiguration.CodingKeys.statusline.stringValue, StatusLineConfiguration.presetKey,
  ]

  /// The builtin layer gives the `default` preset.
  @Test func theBuiltinLayerGivesTheDefaultPreset() async throws {
    let fixture = try SettingsGraphFixture(label: "statusline-default")

    let kept = try await fixture.store.value(at: Self.presetKeyPath, cwd: nil)

    #expect(kept?.value == .string(StatusLineConfiguration.defaultPreset))
    #expect(SettingsEngine.sections.contains(AgentConfiguration.CodingKeys.statusline.stringValue))
  }

  /// An update of the preset at the USER level writes the user file, and
  /// the merged setting gives the value.
  @Test func anUpdateOfThePresetWritesTheUserFile() async throws {
    let fixture = try SettingsGraphFixture(label: "statusline-user")

    let set = try await fixture.run(
      """
      mutation {
        updateSetting(input: {keyPath: ["statusline", "preset"], value: "minimal", level: USER}) {
          value level
        }
      }
      """)
    let read = try await fixture.run(
      "{ setting(keyPath: [\"statusline\"]) { value level } }")

    #expect(set.codes.isEmpty)
    #expect(read.codes.isEmpty)
    let text = try String(
      contentsOf: ConfigCommandFixture.configURL(in: try fixture.userRoot), encoding: .utf8)
    #expect(text.contains("minimal"))
    let merged = try await fixture.store.value(at: Self.presetKeyPath, cwd: nil)
    #expect(merged?.value == .string("minimal"))
    let section = try read.object("setting")
    #expect((section["value"] as? [String: Any])?["preset"] as? String == "minimal")
  }

  /// A module key sets, and the merged configuration keeps the raw value.
  @Test func aModuleKeySetsAndTheConfigurationKeepsTheRawValue() async throws {
    let fixture = try SettingsGraphFixture(label: "statusline-module")

    try await fixture.store.set(
      .int(3), at: ["statusline", "directory", "truncation_length"], level: .user)
    let configuration = try await fixture.store.merged(for: fixture.firstDirectory).configuration

    guard case .object(let fields) = configuration.statusline.value,
      case .object(let directory) = fields["directory"]
    else {
      Issue.record("statusline has no directory module")
      return
    }
    #expect(fields["preset"] == .string(StatusLineConfiguration.defaultPreset))
    #expect(directory["truncation_length"] == .number(3))
  }

  /// An unknown module key is a problem, and the setting stays.
  @Test func anUnknownModuleKeyIsAProblem() async throws {
    let fixture = try SettingsGraphFixture(label: "statusline-unknown-module-key")

    let reply = try await fixture.run(
      """
      mutation {
        updateSetting(
          input: {keyPath: ["statusline", "git_branch", "colour"], value: "red", level: USER}
        ) { value }
      }
      """)

    #expect(!reply.codes.isEmpty)
    #expect(try await fixture.store.value(at: ["statusline", "git_branch"], cwd: nil) == nil)
  }

  /// An unknown top key, a preset that is not a string, and a module that
  /// is not a mapping are problems.
  @Test(arguments: [
    "statusline:\n  colour: red\n",
    "statusline:\n  preset: 3\n",
    "statusline:\n  format: [a]\n",
    "statusline:\n  time: yes\n",
  ])
  func aWrongValueIsAProblem(text: String) throws {
    let root = try YAMLValue.parse(text)

    #expect(throws: (any Error).self) {
      try root.decoded(as: AgentConfiguration.self)
    }
  }

  /// The tool description names the presets and the modules.
  @Test func theToolDescriptionNamesThePresetsAndTheModules() {
    let description = SettingsTool.toolDescription

    for name in StatusLineConfiguration.presets + StatusLineConfiguration.moduleNames {
      #expect(description.contains(name))
    }
  }
}

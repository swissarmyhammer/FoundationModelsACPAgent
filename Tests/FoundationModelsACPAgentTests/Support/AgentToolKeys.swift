@testable import FoundationModelsACPAgent

/// The front matter keys of an agent definition that more than one suite
/// writes. `RunToolSelectionTests`, `SubagentInstructionsTests` and
/// `SessionAgentToolsTests` write the same keys, so each key lives here one
/// time, in the pattern of ``MountOrder``.
enum AgentToolKeys {
  /// The `disallowedTools:` key that denies the `skills` tool. It uses
  /// ``SkillOutputProtection/skillsToolName``, the name that the production
  /// rule uses.
  static let noSkills = "disallowedTools: [\(SkillOutputProtection.skillsToolName)]"
}

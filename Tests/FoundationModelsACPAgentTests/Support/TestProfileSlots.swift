import FoundationModelsRouter

@testable import FoundationModelsACPAgent

extension AgentConfiguration {
  /// Sets the candidates of one slot in a test profile, over the selected
  /// profile. A suite that tests a model that no bundled profile has, and
  /// writes no profile file, uses this.
  ///
  /// - Parameters:
  ///   - slot: The slot of the profile.
  ///   - candidates: The candidates of the slot.
  mutating func setTestSlot(
    _ slot: WritableKeyPath<ProfileDefinition, [ModelRef]>, _ candidates: [ModelRef]
  ) {
    var profile = self.profile.definition
    profile[keyPath: slot] = candidates
    self.profile.resolved = profile
  }
}

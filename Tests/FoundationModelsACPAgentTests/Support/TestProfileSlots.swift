import FoundationModelsRouter

@testable import FoundationModelsACPAgent

extension AgentConfiguration {
  /// Sets the candidates of one slot in a test profile, over the profile
  /// that the preset selects. No settings layer can set a slot (ACPA-21);
  /// a suite that tests a model that no builtin profile has uses this.
  ///
  /// - Parameters:
  ///   - slot: The slot of the profile.
  ///   - candidates: The candidates of the slot.
  mutating func setTestSlot(
    _ slot: WritableKeyPath<ProfileDefinition, [ModelRef]>, _ candidates: [ModelRef]
  ) {
    var profile = self.profile.presetProfile
    profile[keyPath: slot] = candidates
    self.profile.testProfile = profile
  }
}

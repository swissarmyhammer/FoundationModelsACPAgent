import FoundationModelsRouter

extension ModelProfiles {
  /// The default profile: the builtin profile named `defaultName`.
  static var defaultProfile: ProfileDefinition {
    guard let profile = named(defaultName) else {
      preconditionFailure("the builtin profiles of Router have no profile named \(defaultName)")
    }
    return profile
  }
}

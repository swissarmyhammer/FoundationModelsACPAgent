import FoundationModelsRouter

@testable import FoundationModelsACPAgent

/// A fit source with fixed answers by the name of the profile. A test gives
/// it in place of a `Router`, so no test reads the memory of the machine or
/// asks the network.
struct ProfileFitStub: ProfileFitEstimating {
  /// The memory budget of each answer, in bytes.
  static let budgetBytes: Int64 = 2

  /// The bytes of each answer that fits.
  static let requiredBytes: Int64 = 1

  /// The context window of each answer that fits, in tokens.
  static let contextTokens = 52_000

  /// The failure of each answer that does not fit.
  static let failure = "the profile does not fit"

  /// The names of the profiles that fit. Each other profile does not fit.
  let fitting: Set<String>

  /// A fit source where each bundled profile fits.
  static let allFit = ProfileFitStub(fitting: Set(BundledProfiles.names))

  /// A fit source where no profile fits, as when the estimate fails.
  static let noneFit = ProfileFitStub(fitting: [])

  /// The answer of a profile: it fits with ``contextTokens`` when its name
  /// is in ``fitting``, else it does not fit with ``failure``.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The answer.
  func fitReport(of profile: ProfileDefinition) async -> ProfileFitReport {
    guard fitting.contains(profile.name) else {
      return ProfileFitReport(
        fits: false, requiredBytes: nil, budgetBytes: Self.budgetBytes, failure: Self.failure)
    }
    return ProfileFitReport(
      fits: true, requiredBytes: Self.requiredBytes, contextTokens: Self.contextTokens,
      budgetBytes: Self.budgetBytes)
  }
}

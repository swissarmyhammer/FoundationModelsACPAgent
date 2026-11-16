import FoundationModelsRouter

/// The fit of one profile against the memory budget of the machine, as the
/// `models` endpoint shows it. It downloads no model and loads no model.
///
/// Router's `ProfileFitEstimate` (``init(_:)``) gives it in an agent. A test
/// makes one with ``init(fits:requiredBytes:budgetBytes:failure:)``, because
/// Router's type has no public initializer.
public struct ProfileFitReport: Sendable, Equatable {
  /// True when the profile fits the budget.
  public let fits: Bool

  /// The bytes that the profile needs, or `nil` when the profile does not
  /// fit.
  public let requiredBytes: Int64?

  /// The memory budget of the machine, in bytes.
  public let budgetBytes: Int64

  /// The readable reason when the profile does not fit, when a candidate
  /// could not be sized, or when the estimate was cancelled; else `nil`.
  public let failure: String?

  /// Makes a report.
  ///
  /// - Parameters:
  ///   - fits: True when the profile fits the budget.
  ///   - requiredBytes: The bytes that the profile needs, or `nil`.
  ///   - budgetBytes: The memory budget of the machine.
  ///   - failure: The readable reason of a failure, or `nil`.
  public init(fits: Bool, requiredBytes: Int64?, budgetBytes: Int64, failure: String? = nil) {
    self.fits = fits
    self.requiredBytes = requiredBytes
    self.budgetBytes = budgetBytes
    self.failure = failure
  }

  /// The report of a Router estimate.
  ///
  /// - Parameter estimate: The estimate of `Router.estimateFit(of:)`.
  public init(_ estimate: ProfileFitEstimate) {
    self.init(
      fits: estimate.fits, requiredBytes: estimate.requiredBytes,
      budgetBytes: estimate.budgetBytes, failure: estimate.failure)
  }
}

/// A source of the fit of a profile: a `Router` (`Router.estimateFit(of:)`),
/// or a stub in a test. The `models` endpoint reads it for
/// `Query.profiles`. A host that shows the list before the agent exists
/// gives its router, which needs no resolved profile.
public protocol ProfileFitEstimating: Sendable {
  /// The fit of a profile against the memory budget of the machine. It
  /// downloads no model and loads no model.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The report.
  func fitReport(of profile: ProfileDefinition) async -> ProfileFitReport
}

extension Router: ProfileFitEstimating {
  /// The fit of a profile, from `estimateFit(of:)`.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The report.
  public func fitReport(of profile: ProfileDefinition) async -> ProfileFitReport {
    ProfileFitReport(await estimateFit(of: profile))
  }
}

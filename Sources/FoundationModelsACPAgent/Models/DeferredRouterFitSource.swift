import FoundationModelsRouter

/// A fit source whose Router is built at the first fit, then kept for each later fit
/// (task ^8mr8xt2).
///
/// The fit source of a host with no agent, such as `config show` and `doctor`
/// (``ComposedAgent/makeProfileFitSource(for:home:huggingFaceTokenProvider:userLevelOf:)``),
/// builds its Router with the `cluster:` section of the user level, and that read can ask the
/// Keychain for a login secret. A Keychain read can prompt the person, so making this source
/// reads nothing: the build waits for the first fit, as the read of ``ClusterRouterDoctor``
/// waits for its checks.
actor DeferredRouterFitSource: ProfileFitEstimating {
  // MARK: - Types

  /// Builds the Router of the fit.
  typealias RouterSource = @Sendable () throws -> Router

  // MARK: - Constants

  /// The memory budget of the report of a Router that cannot be built: no budget was read.
  private static let unreadBudgetBytes: Int64 = 0

  // MARK: - Stored state

  /// The build of the Router, which the first fit calls.
  private let makeRouter: RouterSource

  /// The outcome of the build, kept so that each fit reads the section and builds the Router
  /// one time at most. `nil` until the first fit.
  private var outcome: Result<Router, any Error>?

  // MARK: - Making

  /// Makes the source over a build of the Router. The build does not run here.
  ///
  /// - Parameter makeRouter: Builds the Router of the fit.
  init(_ makeRouter: @escaping RouterSource) {
    self.makeRouter = makeRouter
  }

  // MARK: - The Router

  /// The Router of the fit: the outcome of the build, which the first call runs.
  ///
  /// - Returns: The Router.
  /// - Throws: What the build throws, at this call and at each later call.
  func router() throws -> Router {
    if let outcome {
      return try outcome.get()
    }
    let built = Result { try makeRouter() }
    if case .failure(let error) = built {
      ACPAgentTelemetry.logger(.configuration).warning(
        "the router of the profile fit cannot be built; no profile fits",
        metadata: ["error": "\(error)"])
    }
    outcome = built
    return try built.get()
  }

  // MARK: - ProfileFitEstimating

  /// The fit of a profile from the Router, or a report that does not fit, with the error of
  /// the build as its failure, when the Router cannot be built.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The report.
  func fitReport(of profile: ProfileDefinition) async -> ProfileFitReport {
    do {
      return try await router().fitReport(of: profile)
    } catch {
      return ProfileFitReport(
        fits: false, requiredBytes: nil, budgetBytes: Self.unreadBudgetBytes,
        failure: String(describing: error))
    }
  }
}

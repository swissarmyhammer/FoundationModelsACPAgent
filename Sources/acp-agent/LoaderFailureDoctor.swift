import FoundationModelsExtras

/// The ``Doctorable`` component that stands in for the six components of
/// `doctor` when the configuration loader cannot be built.
///
/// `doctor` reports a failure as a ``HealthCheck`` with the `error` status
/// and never hides it, so a run with no loader exits 1 with this finding in
/// the report, and not 0 with an empty report.
struct LoaderFailureDoctor: Doctorable {
  /// The group of the finding, the same as the configuration checks.
  static let category = "configuration"

  /// What the finding is called in the report.
  private static let checkName = "the configuration loader"

  /// What this component is called in the doctor report.
  let doctorName = LoaderFailureDoctor.category

  /// The group its finding belongs to.
  let doctorCategory = LoaderFailureDoctor.category

  /// The text of the error that stopped the build of the loader.
  let failure: String

  /// Makes the component over the error of the failed build.
  ///
  /// - Parameter error: The error that the build of the loader threw.
  init(error: any Error) {
    failure = String(describing: error)
  }

  /// Reports the failed build as one error finding.
  ///
  /// - Returns: The one finding, with the status `error`.
  func runHealthChecks() async -> [HealthCheck] {
    [
      .error(
        name: Self.checkName,
        message: "The configuration loader cannot be built: \(failure)",
        fix: "report this defect of acp-agent: its built-in dotfolder name is refused",
        category: Self.category)
    ]
  }
}

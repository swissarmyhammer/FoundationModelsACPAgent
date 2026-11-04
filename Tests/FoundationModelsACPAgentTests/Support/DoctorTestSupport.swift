import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The machine figures that the doctor suites give to the components, so no
/// finding depends on the machine the suite runs on.
enum DoctorMachineFigures {
  /// A memory figure far above the profile floor, so the memory row passes.
  static let generousMemoryBytes: Int64 = 68_719_476_736

  /// A free-disk figure far above any download, so the disk row passes.
  static let generousDiskBytes: Int64 = 1_099_511_627_776
}

extension Array where Element == HealthCheck {
  /// The findings that carry `status`.
  ///
  /// - Parameter status: The status to keep.
  /// - Returns: The findings that carry `status`, in order.
  func findings(_ status: HealthStatus) -> [HealthCheck] {
    filter { $0.status == status }
  }

  /// Asserts that no finding is a warning.
  ///
  /// - Parameter sourceLocation: The test line a failure is reported at.
  func expectNoWarning(sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(findings(.warning).isEmpty, sourceLocation: sourceLocation)
  }
}

extension StubModelResolver {
  /// A lookup table that finds every reference of `references`, each one
  /// already in the cache.
  ///
  /// - Parameter references: The references the table names.
  /// - Returns: The table.
  static func foundLookups(of references: [ModelRef]) -> [String: ModelLookup] {
    Dictionary(
      uniqueKeysWithValues: references.map {
        ($0.stringValue, ModelLookup.found(downloadBytes: 0))
      })
  }
}

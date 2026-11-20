import Foundation
import Testing

@testable import FoundationModelsACPAgent

/// The shared coding of store errors: each conforming enum gives its own
/// map of known errors, and the shared part gives every other error with no
/// change.
@Suite struct StoreCodedErrorTests {
  /// The error that the test map knows.
  struct KnownError: Error {}

  /// An error that the test map does not know.
  struct OtherError: Error, Equatable {}

  /// A coded error with one case, for the error ``KnownError``.
  enum TestCodedError: StoreCodedError, Equatable {
    /// The coded case of ``KnownError``.
    case known

    /// The code of the test case.
    var code: String { "KNOWN" }

    /// The message of the test case.
    var message: String { "The store gave the known error." }

    /// Gives ``known`` for ``KnownError``, and `nil` for each other error.
    static func knownCode(of error: any Error) -> (any Error)? {
      error is KnownError ? TestCodedError.known : nil
    }
  }

  /// A known error becomes the coded case of the map.
  @Test func aKnownErrorBecomesItsCodedCase() {
    #expect(TestCodedError.coded(KnownError()) as? TestCodedError == .known)
  }

  /// An error that the map does not know is given with no change.
  @Test func anOtherErrorIsGivenWithNoChange() {
    #expect(TestCodedError.coded(OtherError()) as? OtherError == OtherError())
  }

  /// A store call that throws a known error throws its coded case.
  @Test func aStoreCallThrowsTheCodedCase() async {
    await #expect(throws: TestCodedError.known) {
      try await TestCodedError.withCodedErrors { () async throws -> Int in throw KnownError() }
    }
  }
}

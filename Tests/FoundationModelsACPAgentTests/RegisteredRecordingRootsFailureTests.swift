import Foundation
import Testing

@testable import FoundationModelsACPAgent

/// The log record of a recording root that cannot be resolved
/// (``RegisteredRecordingRoots/Failure``): each caller reports the failures, and the record holds no
/// path, because a path can hold content.
@Suite struct RegisteredRecordingRootsFailureTests {
  /// An error for the tests.
  private struct Unreadable: Error {}

  /// A folder name that a record must not hold.
  private static let secretFolder = "secret-customer-project"

  @Test("the record of an unreadable project store names the store")
  func registryRecordNamesTheStore() {
    let failure = RegisteredRecordingRoots.Failure.registryUnreadable(Unreadable())

    #expect(failure.logMessage.contains("project store"))
  }

  @Test("the record of an unreadable project names the settings")
  func projectRecordNamesTheSettings() {
    let failure = RegisteredRecordingRoots.Failure.projectUnreadable(
      project: URL(fileURLWithPath: "/work/\(Self.secretFolder)"), error: Unreadable())

    #expect(failure.logMessage.contains("settings"))
  }

  @Test("the record of an unreadable project holds no path")
  func projectRecordHoldsNoPath() {
    let failure = RegisteredRecordingRoots.Failure.projectUnreadable(
      project: URL(fileURLWithPath: "/work/\(Self.secretFolder)"), error: Unreadable())

    #expect(!failure.logMessage.contains(Self.secretFolder))
  }

  @Test("the error of a failure is the error that the resolution met")
  func failureGivesItsError() {
    let failure = RegisteredRecordingRoots.Failure.registryUnreadable(Unreadable())

    #expect(failure.error is Unreadable)
  }
}

import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The selected profile is configuration of the user, as the marketplaces
/// are (D193): a child agent run cannot select a profile through the
/// `settings` engine. A root session and the app can.
@Suite struct ChildRunProfileTests {
  /// The key path of the selected profile.
  private static let profileKeyPath = ProfileConfiguration.keyPath

  /// A settings engine over a fixture store, whose calls run in a child
  /// agent run or not.
  ///
  /// - Parameters:
  ///   - fixture: The settings fixture.
  ///   - isChildRun: Whether each call runs in a child agent run.
  /// - Returns: The engine.
  private static func engine(_ fixture: SettingsGraphFixture, isChildRun: Bool) -> SettingsEngine {
    var engine = SettingsEngine(store: fixture.store)
    engine.isChildRun = { isChildRun }
    return engine
  }

  /// A child run that selects a profile gets the corrective, and the
  /// setting does not change.
  @Test func aChildRunCannotSelectAProfile() async throws {
    let fixture = try SettingsGraphFixture(label: "child-profile-set")

    await #expect(throws: SettingsGraphError.childRunProfile) {
      try await Self.engine(fixture, isChildRun: true).set(
        .string("small"), at: Self.profileKeyPath, level: .user, cwd: nil)
    }
    #expect(try await fixture.store.value(at: Self.profileKeyPath, cwd: nil) == nil)
  }

  /// A child run cannot clear the selected profile either.
  @Test func aChildRunCannotClearTheProfile() async throws {
    let fixture = try SettingsGraphFixture(label: "child-profile-clear")

    await #expect(throws: SettingsGraphError.childRunProfile) {
      try await Self.engine(fixture, isChildRun: true).clear(
        at: Self.profileKeyPath, level: .user, cwd: nil)
    }
  }

  /// A child run still changes an other setting.
  @Test func aChildRunChangesAnOtherSetting() async throws {
    let fixture = try SettingsGraphFixture(label: "child-theme")

    try await Self.engine(fixture, isChildRun: true).set(
      .string("dark"), at: ["theme"], level: .user, cwd: nil)

    #expect(try await fixture.store.value(at: ["theme"], cwd: nil)?.value == .string("dark"))
  }

  /// A root session selects a profile.
  @Test func aRootSessionSelectsAProfile() async throws {
    let fixture = try SettingsGraphFixture(label: "root-profile-set")

    try await Self.engine(fixture, isChildRun: false).set(
      .string("small"), at: Self.profileKeyPath, level: .user, cwd: nil)

    #expect(try await fixture.store.value(at: Self.profileKeyPath, cwd: nil)?.value == .string("small"))
  }
}

import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The folder setting of the content catalog (D214, part 6): the merged value of
/// `spotlight.enabled` for a known folder, and a stream of its changes.
@Suite struct SpotlightFolderSettingsTests {
  /// The key path of `spotlight.enabled`.
  private static let enabledKeyPath = [
    SpotlightConfiguration.sectionKey, SpotlightConfiguration.CodingKeys.enabled.stringValue,
  ]

  /// The key path of `spotlight.tasks`.
  private static let tasksKeyPath = [
    SpotlightConfiguration.sectionKey, SpotlightConfiguration.CodingKeys.tasks.stringValue,
  ]

  /// Reads the changes of `stream` until the first one.
  ///
  /// - Parameter stream: The stream.
  /// - Returns: The change, or `nil` when the stream ends first.
  private static func firstChange(of stream: AsyncStream<SpotlightSettingChange>) async
    -> SpotlightSettingChange?
  {
    for await change in stream {
      return change
    }
    return nil
  }

  /// A folder with no setting gives the default: on.
  @Test func aFolderWithNoSettingIsOn() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-folder-default")
    let settings = SpotlightFolderSettings(store: fixture.store)

    #expect(try await settings.isEnabled(in: fixture.firstDirectory))
  }

  /// `spotlight.enabled: false` at the session level of one folder gives off for that folder and
  /// on for another folder, and the stream names the folder. A change of another key of the
  /// section gives no change.
  @Test func theSessionLevelOfOneFolderTurnsThatFolderOff() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-folder-session")
    let settings = SpotlightFolderSettings(store: fixture.store)
    _ = try await settings.isEnabled(in: fixture.firstDirectory)
    let changes = settings.changes()

    _ = try await fixture.set(
      .bool(false), at: Self.tasksKeyPath, level: SettingsGraphFixture.userLevel, cwd: nil)
    _ = try await fixture.set(
      .bool(false), at: Self.enabledKeyPath, level: SettingsGraphFixture.sessionLevel,
      cwd: fixture.firstDirectory)

    let change = await Self.firstChange(of: changes)
    #expect(change == .folder(fixture.firstDirectory.standardizedFileURL))
    #expect(try await settings.isEnabled(in: fixture.firstDirectory) == false)
    #expect(try await settings.isEnabled(in: fixture.secondDirectory) == true)
  }

  /// `spotlight.enabled: false` at the user level turns each folder with no session-level value
  /// off, and the stream names the user level.
  @Test func theUserLevelTurnsEachFolderOff() async throws {
    let fixture = try SettingsGraphFixture(label: "spotlight-folder-user")
    let settings = SpotlightFolderSettings(store: fixture.store)
    let changes = settings.changes()

    _ = try await fixture.set(
      .bool(false), at: Self.enabledKeyPath, level: SettingsGraphFixture.userLevel, cwd: nil)

    #expect(await Self.firstChange(of: changes) == .user)
    #expect(try await settings.isEnabled(in: fixture.secondDirectory) == false)
  }
}

import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// The map of ``SnapshotSessionKeys`` between the ACP sessions and their
/// snapshot session keys. The Router session of an ACP session has the id of
/// the ACP session for its whole life, so the map holds no Router id.
///
/// Each test makes its own map, so no test reads the map of the process.
@Suite struct SnapshotSessionKeysTests {
  /// The ACP session, which is the id of its Router session too.
  private static let acpSession = SessionId(rawValue: "01M5M8ACPSESSION0000000000")

  /// The session key of the ACP session.
  private static let sessionKey = "SnapshotSessionKeysTests-key"

  /// A recorded key is the key of its session.
  @Test
  func aRecordedKeyIsTheKeyOfItsSession() {
    let keys = SnapshotSessionKeys()

    keys.record(Self.sessionKey, for: Self.acpSession)

    #expect(keys.sessionKey(of: Self.acpSession.rawValue) == Self.sessionKey)
  }

  /// A session that no agent recorded has no key.
  @Test
  func aSessionThatNoAgentRecordedHasNoKey() {
    let keys = SnapshotSessionKeys()

    #expect(keys.sessionKey(of: Self.acpSession.rawValue) == nil)
  }

  /// The delete of the ACP session forgets its key.
  @Test
  func aDeleteForgetsTheKeyOfTheSession() {
    let keys = SnapshotSessionKeys()
    keys.record(Self.sessionKey, for: Self.acpSession)

    keys.forget(Self.acpSession)

    #expect(keys.sessionKey(of: Self.acpSession.rawValue) == nil)
  }
}
